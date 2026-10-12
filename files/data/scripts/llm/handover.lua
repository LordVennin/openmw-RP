-- Finds what vanilla Morrowind does when the player hands an item to an NPC, so items given during an AI
-- conversation advance quests the same way. Hundreds of dialogue lines take an item from the player in their
-- result script (`player->removeitem "x" 1`), usually together with `Journal <quest> <stage>`. When the player gives
-- item X to an NPC, the NPC's first line that removes X and passes its filters is used, and only a safe subset of
-- its result script is applied: journal entries, the NPC's own local variables and a capped disposition change.

local core = require('openmw.core')
local types = require('openmw.types')
local vfs = require('openmw.vfs')

local json = require('scripts.llm.json')
local knowledge = require('scripts.llm.knowledge')

local M = {}

local MAX_DISPOSITION_CHANGE = 20

-- item id -> list of { info, record, type }, built on first use
local index = nil
-- Hand-written hooks from llm/quests/*.json, checked before the vanilla lines; loaded on first use
local overrides = nil

local function loadOverrides()
    overrides = {}
    for path in vfs.pathsWithPrefix('llm/quests') do
        if path:lower():match('%.json$') then
            local file = vfs.open(path)
            local content = file and file:read('*a')
            if file then
                file:close()
            end
            local ok, data = pcall(json.decode, content or '')
            if ok and type(data) == 'table' and type(data.hooks) == 'table' then
                for _, hook in ipairs(data.hooks) do
                    if type(hook.npc) == 'string' and type(hook.item) == 'string' then
                        overrides[#overrides + 1] = hook
                    end
                end
            else
                print('LLM: could not parse quest hooks ' .. path .. ': ' .. tostring(data))
            end
        end
    end
end

local function questStage(player, quest)
    local entry = types.Player.quests(player)[quest:lower()]
    return entry and entry.stage or 0
end

local function findOverride(npc, player, itemId)
    if not overrides then
        loadOverrides()
    end
    for _, hook in ipairs(overrides) do
        if hook.npc:lower() == npc.recordId:lower() and hook.item:lower() == itemId:lower()
            and (hook.transfer == nil or hook.transfer == 'player_to_npc') then
            local below = hook.requireQuestBelow
            if not below or questStage(player, below.quest) < below.stage then
                local effects = { locals = {}, text = 'override: ' .. (hook.note or hook.item) }
                if type(hook.journal) == 'table' then
                    effects.journal = { quest = hook.journal.quest:lower(), stage = hook.journal.stage }
                end
                for name, value in pairs(type(hook.setLocal) == 'table' and hook.setLocal or {}) do
                    effects.locals[name:lower()] = value
                end
                if type(hook.disposition) == 'number' then
                    effects.disposition = math.max(-MAX_DISPOSITION_CHANGE, math.min(MAX_DISPOSITION_CHANGE, hook.disposition))
                end
                effects.note = hook.note
                return effects
            end
        end
    end
    return nil
end

local function removedItems(script)
    local items = {}
    for id in script:lower():gmatch('player%s*%->%s*removeitem%s*,?%s*"?([^"%s,]+)"?') do
        items[id] = true
    end
    return items
end

local function buildIndex()
    index = {}
    for _, dialogueType in ipairs({ 'topic', 'greeting' }) do
        for _, record in pairs(core.dialogue[dialogueType].records) do
            for _, info in ipairs(record.infos) do
                local script = info.resultScript
                if script and script:lower():find('removeitem', 1, true) then
                    for id in pairs(removedItems(script)) do
                        index[id] = index[id] or {}
                        table.insert(index[id], { info = info, record = record, type = dialogueType })
                    end
                end
            end
        end
    end
end

-- Extracts the safe commands from a vanilla result script.
-- @return { journal = { quest, stage } or nil, locals = { name = number }, disposition = number or nil }
function M.parseResultScript(script)
    local effects = { locals = {} }
    for rawLine in (script .. '\n'):gmatch('([^\r\n]*)\r?\n') do
        local line = rawLine:gsub(';.*$', ''):gsub('^%s+', ''):gsub('%s+$', ''):lower()
        local quest, stage = line:match('^journal%s*,?%s*"?([%w_]+)"?%s*,?%s*(%-?%d+)$')
        if quest then
            effects.journal = { quest = quest, stage = tonumber(stage) }
        end
        -- Only the speaker's own variables: no "object->" prefix and no "script.variable"
        local name, value = line:match('^set%s+([%w_]+)%s+to%s+(%-?%d+%.?%d*)$')
        if name then
            effects.locals[name] = tonumber(value)
        end
        local delta = line:match('^moddisposition%s*,?%s*(%-?%d+)$')
        if delta then
            local n = tonumber(delta)
            effects.disposition = math.max(-MAX_DISPOSITION_CHANGE, math.min(MAX_DISPOSITION_CHANGE, n))
        end
    end
    return effects
end

local function hasEffects(effects)
    return effects.journal ~= nil or effects.disposition ~= nil or next(effects.locals) ~= nil
end

-- @param npc the NPC receiving the item
-- @param player the player object
-- @param itemId record id of the item being given (before it moves, so "player has the item" conditions pass)
-- @param locals the NPC's mwscript variables, or nil
-- @return effects table with `text` (the matched vanilla line) and `topic`, or nil
function M.find(npc, player, itemId, locals)
    local override = findOverride(npc, player, itemId)
    if override then
        return override
    end
    if not index then
        buildIndex()
    end
    local candidates = index[itemId:lower()]
    if not candidates then
        return nil
    end
    local ctx = knowledge.newContext(npc, player, locals, true)
    for _, candidate in ipairs(candidates) do
        local info = candidate.info
        local ok, passes = pcall(knowledge.infoPasses, info, ctx)
        if ok and passes then
            local effects = M.parseResultScript(info.resultScript)
            local stageReached = false
            if effects.journal then
                local quest = types.Player.quests(player)[effects.journal.quest]
                stageReached = quest ~= nil and quest.stage >= effects.journal.stage
            end
            if not stageReached and hasEffects(effects) then
                effects.text = info.text
                effects.topic = candidate.record.name
                return effects
            end
        end
    end
    return nil
end

return M
