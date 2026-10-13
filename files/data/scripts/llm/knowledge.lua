-- A lorebook built from the game's own dialogue. The NPC's vanilla answers to dialogue topics are added to the
-- prompt, so the model knows what the NPC would say if the player clicked the topic. Included, within a budget:
--   1. the NPC's own topic (named after them, e.g. "Vodunius Nuccius"), where vanilla keeps their personal story;
--   2. topics mentioned in the conversation (e.g. "ring");
--   3. the NPC's other personal topics (topics with lines written specifically for them).
--
-- Vanilla picks the first response whose filters and conditions all pass. Lua can evaluate most of them.
-- The speaker's mwscript variables come from a snapshot taken by the global script (scripts/llm/global.lua).
-- Lines gated on things a player script can't read (global variables, death counts, or local variables when no
-- snapshot is available) are skipped: they almost always mark a later quest state, so skipping them falls
-- through to the line the NPC would say now.

local core = require('openmw.core')
local types = require('openmw.types')

local budget = require('scripts.llm.budget')

local M = {}

local topicIndex = nil
-- npc record id -> list of topic records that have lines written for that NPC
local personalIndex = nil

local function getPersonalTopics(recordId)
    if not personalIndex then
        personalIndex = {}
        for _, record in pairs(core.dialogue.topic.records) do
            local seen = {}
            for _, info in ipairs(record.infos) do
                local actor = info.filterActorId and info.filterActorId:lower()
                if actor and not seen[actor] then
                    seen[actor] = true
                    personalIndex[actor] = personalIndex[actor] or {}
                    table.insert(personalIndex[actor], record)
                end
            end
        end
    end
    return personalIndex[recordId:lower()] or {}
end

-- All topic names, longest first so "little secret" wins over "secret"
local function getTopicIndex()
    if not topicIndex then
        topicIndex = {}
        for _, record in pairs(core.dialogue.topic.records) do
            if record.name and #record.name >= 3 then
                topicIndex[#topicIndex + 1] = { id = record.id, name = record.name, lower = record.name:lower() }
            end
        end
        table.sort(topicIndex, function(a, b)
            return #a.lower > #b.lower
        end)
    end
    return topicIndex
end

local function escapePattern(s)
    return (s:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0'))
end

local function mentions(text, topicLower)
    return text:find('%f[%w]' .. escapePattern(topicLower) .. '%f[%W]') ~= nil
end

-- Topics mentioned in any of `texts`, at most `limit`
function M.findTopics(texts, limit)
    local haystack = table.concat(texts, '\n'):lower()
    local found = {}
    for _, topic in ipairs(getTopicIndex()) do
        if mentions(haystack, topic.lower) then
            found[#found + 1] = topic
            -- Don't also match words inside a longer topic that was already found
            haystack = haystack:gsub(escapePattern(topic.lower), ' ')
            if #found >= limit then
                break
            end
        end
    end
    return found
end

local function lower(s)
    return s and s:lower() or nil
end

local function compare(op, a, b)
    local O = core.dialogue.CONDITION_OPERATOR
    if op == O.Equal then
        return a == b
    elseif op == O.NotEqual then
        return a ~= b
    elseif op == O.Greater then
        return a > b
    elseif op == O.GreaterEqual then
        return a >= b
    elseif op == O.Less then
        return a < b
    elseif op == O.LessEqual then
        return a <= b
    end
    return true
end

local function inFaction(actor, factionId)
    local ok, factions = pcall(types.NPC.getFactions, actor)
    for _, id in ipairs(ok and factions or {}) do
        if id:lower() == factionId then
            return true
        end
    end
    return false
end

-- Evaluates one condition. Conditions a player script can't read fail; other unhandled ones pass.
local function conditionPasses(condition, ctx)
    local T = core.dialogue.CONDITION_TYPE
    local t = condition.type
    local id = lower(condition.recordId)
    local value
    if t == T.Choice then
        return ctx.ignoreChoice == true -- answers inside a vanilla choice menu
    elseif t == T.Local or t == T.NotLocal then
        local locals = ctx.locals
        if not locals then
            return false
        end
        local current = locals[lower(condition.variableName)]
        if t == T.NotLocal then
            return current == nil -- the speaker's script doesn't declare this variable
        end
        if current == nil then
            return false
        end
        value = current
    elseif t == T.Global or t == T.Dead then
        return false -- global variables and death counts aren't readable here
    elseif t == T.Journal then
        local quest = types.Player.quests(ctx.player)[id]
        value = quest and quest.stage or 0
    elseif t == T.Item then
        value = types.Actor.inventory(ctx.player):countOf(id)
    elseif t == T.NotId then
        return ctx.npc.recordId:lower() ~= id
    elseif t == T.NotFaction then
        return lower(ctx.npcRecord.primaryFaction) ~= id
    elseif t == T.NotClass then
        return lower(ctx.npcRecord.class) ~= id
    elseif t == T.NotRace then
        return lower(ctx.npcRecord.race) ~= id
    elseif t == T.NotCell then
        local cellName = lower(ctx.player.cell.name) or ''
        return cellName:sub(1, #(condition.cellName or '')) ~= lower(condition.cellName or '')
    elseif t == T.PcLevel then
        value = types.Actor.stats.level(ctx.player).current
    elseif t == T.PcGender then
        value = ctx.playerRecord.isMale and 0 or 1
    elseif t == T.SameRace then
        value = (lower(ctx.npcRecord.race) == lower(ctx.playerRecord.race)) and 1 or 0
    elseif t == T.SameGender then
        value = (ctx.npcRecord.isMale == ctx.playerRecord.isMale) and 1 or 0
    elseif t == T.PcCrimeLevel then
        value = types.Player.getCrimeLevel(ctx.player)
    elseif t == T.PcReputation then
        value = types.NPC.stats.reputation(ctx.player).current
    elseif t == T.Reputation then
        value = types.NPC.stats.reputation(ctx.npc).current
    elseif t == T.Level then
        value = types.Actor.stats.level(ctx.npc).current
    elseif t == T.PcExpelled or t == T.SameFaction or t == T.FactionRankDifference then
        local faction = ctx.npcRecord.primaryFaction
        if not faction or faction == '' then
            value = 0
        elseif t == T.PcExpelled then
            value = types.NPC.isExpelled(ctx.player, faction) and 1 or 0
        elseif t == T.SameFaction then
            value = inFaction(ctx.player, faction:lower()) and 1 or 0
        else
            -- Both ranks are 1-based here (0 for the player outside the faction), so the difference matches vanilla's
            value = types.NPC.getFactionRank(ctx.player, faction) - ctx.npcRecord.primaryFactionRank
        end
    else
        return true
    end
    return compare(condition.operator, value, condition.value)
end

function M.infoPasses(info, ctx)
    if info.filterActorId and info.filterActorId:lower() ~= ctx.npc.recordId:lower() then
        return false
    end
    if info.filterActorRace and info.filterActorRace:lower() ~= lower(ctx.npcRecord.race) then
        return false
    end
    if info.filterActorClass and info.filterActorClass:lower() ~= lower(ctx.npcRecord.class) then
        return false
    end
    if info.filterActorGender and (info.filterActorGender == 'male') ~= ctx.npcRecord.isMale then
        return false
    end
    -- Faction and rank filters, as MWDialogue::Filter::testActor and testPlayer: the speaker's primary faction and
    -- rank, the player's membership and rank (ranks are 1-based here, 0 when not a member)
    local npcFaction = lower(ctx.npcRecord.primaryFaction) or ''
    if info.filterActorFaction == '' then
        if npcFaction ~= '' then
            return false -- a line for speakers without a faction
        end
    elseif info.filterActorFaction then
        if npcFaction ~= info.filterActorFaction:lower() then
            return false
        end
    end
    if info.filterActorFactionRank and info.filterActorFaction ~= '' then
        if npcFaction == '' or types.NPC.getFactionRank(ctx.npc, npcFaction) < info.filterActorFactionRank then
            return false
        end
    end
    local playerFaction = info.filterPlayerFaction and info.filterPlayerFaction:lower()
    if not playerFaction and info.filterPlayerFactionRank then
        playerFaction = npcFaction -- a player rank without a faction means the speaker's faction
    end
    if playerFaction then
        local rank = playerFaction ~= '' and types.NPC.getFactionRank(ctx.player, playerFaction) or 0
        if rank == 0 or rank < (info.filterPlayerFactionRank or 1) then
            return false
        end
    end
    if info.filterPlayerCell then
        local cellName = lower(ctx.player.cell.name) or ''
        if cellName:sub(1, #info.filterPlayerCell) ~= info.filterPlayerCell:lower() then
            return false
        end
    end
    if info.filterActorDisposition and ctx.disposition and ctx.disposition < info.filterActorDisposition then
        return false
    end
    for _, condition in ipairs(info.conditions or {}) do
        local ok, passes = pcall(conditionPasses, condition, ctx)
        if not ok or not passes then
            return false
        end
    end
    return true
end

-- The first response to `topicId` that this NPC would give, or nil
function M.responseFor(topicId, ctx)
    local record = core.dialogue.topic.records[topicId]
    if not record then
        return nil
    end
    for _, info in ipairs(record.infos) do
        if info.text and info.text ~= '' and M.infoPasses(info, ctx) then
            return info.text
        end
    end
    return nil
end

-- Everything the filters need to know about the speaker and the player.
-- @param locals the speaker's mwscript variables (lower-case names), or nil if unknown
-- @param ignoreChoice true to let lines behind a vanilla choice pass
function M.newContext(npc, player, locals, ignoreChoice)
    local ctx = {
        npc = npc,
        player = player,
        npcRecord = types.NPC.record(npc),
        playerRecord = types.NPC.record(player),
        locals = locals,
        ignoreChoice = ignoreChoice,
    }
    local ok, disposition = pcall(types.NPC.getDisposition, npc, player)
    ctx.disposition = ok and disposition or nil
    return ctx
end

-- @param npc, player game objects
-- @param texts list of strings to look for topic names in (the player's line, the NPC's last line)
-- @param expand function(text) -> text expanding vanilla macros (%PCName...)
-- @param limits table from budget.fromContextSize
-- @param locals the speaker's mwscript variables, or nil
-- @return the "[Knowledge]" note, or nil
function M.build(npc, player, texts, expand, limits, locals)
    local ctx = M.newContext(npc, player, locals, false)

    -- Candidate topics in priority order: own topic, mentioned topics, other personal topics
    local npcName = ctx.npcRecord.name:lower()
    local own, others = {}, {}
    for _, record in ipairs(getPersonalTopics(npc.recordId)) do
        local entry = { id = record.id, name = record.name }
        if record.name:lower() == npcName then
            own[#own + 1] = entry
        else
            others[#others + 1] = entry
        end
    end
    table.sort(others, function(a, b)
        return a.name < b.name
    end)
    local candidates = {}
    for _, list in ipairs({ own, M.findTopics(texts, limits.maxTopics), others }) do
        for _, topic in ipairs(list) do
            candidates[#candidates + 1] = topic
        end
    end

    -- The budget is shared, not split evenly: earlier (more important) topics can use what they need, so the
    -- NPC's own story isn't cut short; only the topic that overflows the remaining budget is truncated.
    local lines, seen = {}, {}
    local remaining = limits.knowledgeTokens
    for _, topic in ipairs(candidates) do
        if #lines >= limits.maxTopics or remaining < 30 then
            break
        end
        if not seen[topic.id] then
            seen[topic.id] = true
            local found, text = pcall(M.responseFor, topic.id, ctx)
            if found and text then
                text = budget.truncate((expand(text):gsub('%s+', ' ')), remaining)
                remaining = remaining - budget.estimateTokens(text)
                lines[#lines + 1] = string.format('- About "%s", %s would say: %s', topic.name, ctx.npcRecord.name, text)
            end
        end
    end
    if #lines == 0 then
        return nil
    end
    return '[What ' .. ctx.npcRecord.name .. ' knows]\n' .. table.concat(lines, '\n')
end

return M
