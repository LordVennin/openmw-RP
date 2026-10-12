-- Global half of AI dialogue: applies validated item exchanges, quest effects, persuasion and followers, which
-- player scripts can't do, and reads NPCs' mwscript variables for the dialogue filters.

local types = require('openmw.types')
local world = require('openmw.world')

local MAX_ITEM_COUNT = 10
local MAX_GOLD = 1000
local MAX_DISPOSITION_CHANGE = 100
local MAX_REWARD_COUNT = 5000
local GOLD_ID = 'gold_001'

-- Disposition changes for NPCs that weren't loaded when they were earned (e.g. Arrille, who is inside his
-- tradehouse while the player talks to Fargoth outside): npc record id -> { player = object, delta = number }.
-- Applied when the NPC becomes active; saved with the game.
local deferred = {}

local function clampDisposition(delta)
    return math.max(-MAX_DISPOSITION_CHANGE, math.min(MAX_DISPOSITION_CHANGE, delta))
end

-- NPCs following the player because of an AI conversation: npc id -> { npc, player, state, home, reason }.
-- state is 'following', 'waiting' or 'goingHome'; home is { cellName, position } where they were recruited.
-- Saved with the game.
local followers = {}
local followerCheckTimer = 0

local function homeOf(npc)
    local cell = npc.cell
    return { cellName = cell.isExterior and '' or cell.name, position = npc.position }
end

local function startFollowing(data)
    local npc, player = data.npc, data.player
    local entry = followers[npc.id] or { npc = npc, home = homeOf(npc) }
    entry.player = player
    entry.state = 'following'
    entry.reason = data.reason or entry.reason
    followers[npc.id] = entry
    npc:sendEvent('RemoveAIPackages', 'Wander')
    npc:sendEvent('StartAIPackage', { type = 'Follow', target = player })
end

local function wait(data)
    local entry = followers[data.npc.id]
    if not entry then
        return
    end
    entry.state = 'waiting'
    data.npc:sendEvent('RemoveAIPackages', 'Follow')
    data.npc:sendEvent('StartAIPackage', { type = 'Wander', distance = 0 })
end

local function dismiss(data)
    local entry = followers[data.npc.id]
    if not entry then
        return
    end
    entry.state = 'goingHome'
    data.npc:sendEvent('RemoveAIPackages', 'Follow')
end

-- Dismissed followers are sent home once the player is elsewhere, so it never happens in sight
local function updateFollowers(dt)
    followerCheckTimer = followerCheckTimer + dt
    if followerCheckTimer < 1 then
        return
    end
    followerCheckTimer = 0
    for id, entry in pairs(followers) do
        local npc = entry.npc
        if not npc:isValid() or types.Actor.isDead(npc) then
            followers[id] = nil
        elseif entry.state == 'goingHome' and entry.player:isValid() and npc.cell ~= entry.player.cell then
            npc:teleport(entry.home.cellName, entry.home.position)
            npc:sendEvent('RemoveAIPackages', 'Wander')
            followers[id] = nil
            print('LLM followers: sent ' .. npc.recordId .. ' home')
        end
    end
end

local function applyDeferred(actor)
    local pending = deferred[actor.recordId:lower()]
    if pending and types.NPC.objectIsInstance(actor) and pending.player and pending.player:isValid() then
        types.NPC.modifyBaseDisposition(actor, pending.player, clampDisposition(pending.delta))
        deferred[actor.recordId:lower()] = nil
        print(string.format('LLM handover: applied deferred disposition %+d to %s', pending.delta, actor.recordId))
    end
end

local function itemName(recordId, inventory, object)
    local item = object or (inventory and inventory:find(recordId))
    if item then
        local ok, record = pcall(item.type.record, item)
        if ok and record and record.name then
            return record.name
        end
    end
    return recordId
end

-- Moves `count` items with `recordId` between two actors' inventories, across stacks
local function moveItems(from, to, recordId, count)
    local source = types.Actor.inventory(from)
    if source:countOf(recordId) < count then
        return false
    end
    local destination = types.Actor.inventory(to)
    local remaining = count
    for _, stack in ipairs(source:findAll(recordId)) do
        if remaining <= 0 then
            break
        end
        local n = math.min(stack.count, remaining)
        local part = n < stack.count and stack:split(n) or stack
        part:moveInto(destination)
        remaining = remaining - n
    end
    return true
end

local function localVariables(npc)
    local ok, script = pcall(world.mwscript.getLocalScript, npc)
    if not ok or not script then
        return nil
    end
    local vars = {}
    for name, value in pairs(script.variables) do
        vars[name:lower()] = value
    end
    return vars
end

local function applyEffects(player, npc, effects)
    local applied = {}
    if effects.journal then
        local quest = types.Player.quests(player)[effects.journal.quest]
        if quest and quest.stage < effects.journal.stage then
            quest:addJournalEntry(effects.journal.stage, npc)
            applied.journal = true
        end
    end
    if effects.locals and next(effects.locals) then
        local ok, script = pcall(world.mwscript.getLocalScript, npc)
        if ok and script then
            for name, value in pairs(effects.locals) do
                local set = pcall(function()
                    script.variables[name] = value
                end)
                if set then
                    applied.locals = true
                end
            end
        end
    end
    if effects.disposition then
        local delta = clampDisposition(effects.disposition)
        types.NPC.modifyBaseDisposition(npc, player, delta)
        applied.disposition = delta
    end
    -- Other NPCs' disposition: now if they are loaded, otherwise when they next become active
    for recordId, delta in pairs(effects.others or {}) do
        local id = recordId:lower()
        local current = deferred[id]
        deferred[id] = { player = player, delta = (current and current.delta or 0) + delta }
        for _, actor in ipairs(world.activeActors) do
            if actor.recordId:lower() == id then
                applyDeferred(actor)
                break
            end
        end
        applied.others = true
    end
    -- Item rewards from the vanilla script
    applied.rewards = {}
    for _, reward in ipairs(effects.rewards or {}) do
        local count = math.min(reward.count or 1, MAX_REWARD_COUNT)
        local ok, item = pcall(world.createObject, reward.id, count)
        if ok and item then
            local name = itemName(reward.id, nil, item)
            item:moveInto(types.Actor.inventory(player))
            applied.rewards[#applied.rewards + 1] = { name = name, count = count }
        else
            print('LLM handover: could not create reward ' .. tostring(reward.id))
        end
    end
    -- Faction reputation; without a faction name it's the speaker's own faction
    for _, change in ipairs(effects.factionRep or {}) do
        local faction = change.faction
        if not faction then
            local ok, record = pcall(types.NPC.record, npc)
            faction = ok and record and record.primaryFaction or nil
        end
        if faction and faction ~= '' then
            local ok = pcall(function()
                local current = types.NPC.getFactionReputation(player, faction)
                types.NPC.setFactionReputation(player, faction, current + change.amount)
            end)
            if ok then
                applied.factionRep = true
            end
        end
    end
    return applied
end

local function onApplyTransfer(data)
    local player, npc = data.player, data.npc
    local result = { transfer = data.transfer, item = data.item, count = data.count, ok = false }
    local cap = data.item == GOLD_ID and MAX_GOLD or MAX_ITEM_COUNT
    local count = math.min(math.floor(tonumber(data.count) or 0), cap)
    local from, to = player, npc
    if data.transfer == 'npc_to_player' then
        from, to = npc, player
    end
    if count <= 0 or not npc:isValid() or types.Actor.isDead(npc) then
        result.error = 'invalid request'
    else
        result.name = itemName(data.item, types.Actor.inventory(from))
        if moveItems(from, to, data.item, count) then
            result.ok = true
            result.count = count
            if data.effects then
                result.applied = applyEffects(player, npc, data.effects)
                print(string.format('LLM handover: %s gave %s to %s; vanilla line "%s" -> journal=%s locals=%s '
                    .. 'disposition=%s others=%s rewards=%d factionRep=%s', types.NPC.record(player).name, data.item,
                    types.NPC.record(npc).name, tostring(data.effects.text), tostring(result.applied.journal),
                    tostring(result.applied.locals), tostring(result.applied.disposition),
                    tostring(result.applied.others), #result.applied.rewards, tostring(result.applied.factionRep)))
            end
        else
            result.error = 'not enough items'
        end
    end
    player:sendEvent('LLMTransferApplied', result)
    player:sendEvent('LLMLocals', { npc = npc, vars = localVariables(npc) })
end

return {
    engineHandlers = {
        onActorActive = applyDeferred,
        onUpdate = updateFollowers,
        onSave = function()
            return { version = 2, deferred = deferred, followers = followers }
        end,
        onLoad = function(data)
            deferred = (data and data.deferred) or {}
            followers = (data and data.version == 2 and data.followers) or {}
        end,
    },
    eventHandlers = {
        LLMApplyTransfer = onApplyTransfer,
        LLMGetLocals = function(data)
            data.player:sendEvent('LLMLocals', { npc = data.npc, vars = localVariables(data.npc) })
        end,
        LLMSetLocals = function(data)
            applyEffects(data.player, data.npc, { locals = data.locals })
        end,
        -- Persuasion: a temporary change during the conversation, then the final value when it ends
        LLMModDisposition = function(data)
            types.NPC.modifyBaseDisposition(data.npc, data.player, clampDisposition(data.delta))
        end,
        LLMSetBaseDisposition = function(data)
            types.NPC.setBaseDisposition(data.npc, data.player, math.max(0, math.min(100, data.value)))
        end,
        -- Fight/Flee changes from persuasion, applied by a script on the NPC itself
        LLMModAI = function(data)
            local npc = data.npc
            if not npc:isValid() then
                return
            end
            if not npc:hasScript('scripts/llm/npc.lua') then
                npc:addScript('scripts/llm/npc.lua')
            end
            npc:sendEvent('LLMModAI', { fight = data.fight, flee = data.flee })
        end,
        LLMFollow = startFollowing,
        LLMWait = wait,
        LLMDismiss = dismiss,
        LLMGetFollowers = function(data)
            local list = {}
            for _, entry in pairs(followers) do
                list[#list + 1] = { npc = entry.npc, state = entry.state, reason = entry.reason }
            end
            data.player:sendEvent('LLMFollowers', { followers = list })
        end,
    },
}
