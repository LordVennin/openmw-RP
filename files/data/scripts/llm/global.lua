-- Global half of AI dialogue: applies validated item exchanges and quest effects, which player scripts can't do,
-- and reads NPCs' mwscript variables for the dialogue filters.

local types = require('openmw.types')
local world = require('openmw.world')

local MAX_ITEM_COUNT = 10
local MAX_GOLD = 1000
local MAX_DISPOSITION_CHANGE = 20
local GOLD_ID = 'gold_001'

local function itemName(recordId, inventory)
    local item = inventory:find(recordId)
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
        local delta = math.max(-MAX_DISPOSITION_CHANGE, math.min(MAX_DISPOSITION_CHANGE, effects.disposition))
        types.NPC.modifyBaseDisposition(npc, player, delta)
        applied.disposition = delta
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
                    .. 'disposition=%s', types.NPC.record(player).name, data.item, types.NPC.record(npc).name,
                    tostring(data.effects.text), tostring(result.applied.journal), tostring(result.applied.locals),
                    tostring(result.applied.disposition)))
            end
        else
            result.error = 'not enough items'
        end
    end
    player:sendEvent('LLMTransferApplied', result)
    player:sendEvent('LLMLocals', { npc = npc, vars = localVariables(npc) })
end

return {
    eventHandlers = {
        LLMApplyTransfer = onApplyTransfer,
        LLMGetLocals = function(data)
            data.player:sendEvent('LLMLocals', { npc = data.npc, vars = localVariables(data.npc) })
        end,
        LLMSetLocals = function(data)
            applyEffects(data.player, data.npc, { locals = data.locals })
        end,
    },
}
