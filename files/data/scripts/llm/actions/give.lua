-- Items and gold changing hands. Nothing moves without the player's click:
--   give       (intent) the player hands the NPC something. The player confirms ("Give X" / "Keep it") before the
--              reply; the handover is applied first, with vanilla quest effects and rewards (scripts/llm/handover.lua),
--              so the reply can react to it.
--   give_item  (proposal) the NPC hands the player something in their reply; the player accepts or refuses.
-- Only items actually in the giver's inventory and mentioned in the exchange can be named by the model.

local handover = require('scripts.llm.handover')
local check = require('scripts.llm.actions.check')

local M = {}

local function itemLabel(name, count)
    return count > 1 and (count .. ' ' .. name) or name
end
M.itemLabel = itemLabel

local numberWords = { 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'twenty', 'thirty',
    'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety', 'hundred', 'thousand' }

-- Whether the player named an amount themselves ("20 gold", "fifty drakes")
function M.namesAmount(text)
    local lower = text:lower()
    if lower:find('%d') then
        return true
    end
    for _, word in ipairs(numberWords) do
        if lower:find('%f[%a]' .. word .. '%f[%A]') then
            return true
        end
    end
    return false
end

-- When the player gives an NPC something a vanilla quest line asks for, use the quest's amount (e.g. Vodunius
-- Nuccius's 100 drakes) instead of the model's guess, as long as the player has that many and didn't name an
-- amount of their own.
local function useQuestAmount(game, turn, transfer, candidates)
    if transfer.transfer ~= check.PLAYER_GIVES or M.namesAmount(turn.userText) then
        return
    end
    local ok, required = pcall(handover.requiredCount, turn.npc, game.player, transfer.item, game.locals(turn.npc))
    if not ok or not required then
        return
    end
    for _, c in ipairs(candidates) do
        if c.id == transfer.item and c.playerCount >= required then
            transfer.count = required
            return
        end
    end
end

-- Moves the item through the global script, with vanilla quest effects when the player gives, then calls
-- done(result, label, rewards) once it has happened (result.ok false if it failed).
local function applyTransfer(game, turn, transfer, done)
    local effects = nil
    if transfer.transfer == check.PLAYER_GIVES then
        local ok, found = pcall(handover.find, turn.npc, game.player, transfer.item, game.locals(turn.npc),
            transfer.count)
        effects = ok and found or nil
        if not ok then
            print('LLM handover lookup: ' .. tostring(found))
        end
    end
    game.globalRequest(turn, 'LLMApplyTransfer', {
        player = game.player,
        npc = turn.npc,
        transfer = transfer.transfer,
        item = transfer.item,
        count = transfer.count,
        effects = effects,
    }, function(result)
        if not result.ok then
            print('LLM transfer failed: ' .. tostring(result.error))
            done(result)
            return
        end
        local label = itemLabel(result.name, result.count)
        game.notice(result.transfer == check.PLAYER_GIVES and 'itemRemoved' or 'itemAdded', { item = label })
        -- No journal notice here: the engine shows "Your journal has been updated" itself when an entry is added
        local rewards = {}
        for _, reward in ipairs(result.applied and result.applied.rewards or {}) do
            local rewardLabel = itemLabel(reward.name, reward.count)
            rewards[#rewards + 1] = rewardLabel
            game.notice('itemAdded', { item = rewardLabel })
        end
        local event
        if effects and effects.note then
            event = effects.note
        elseif result.transfer == check.PLAYER_GIVES then
            event = string.format('The stranger gave %s %s.', turn.npcName, label)
        else
            event = string.format('%s gave the stranger %s.', turn.npcName, label)
        end
        if #rewards > 0 then
            event = event .. string.format(' %s rewarded the stranger with %s.', turn.npcName, table.concat(rewards, ', '))
        end
        game.historyEvent(turn.npc, event)
        done(result, label, rewards, effects)
    end)
end

-- The player gives: confirm, apply, and tell the model what happened (with vanilla's reaction) before the reply
local function give(game, turn, params)
    local transfer = params.transfer
    useQuestAmount(game, turn, transfer, params.candidates)
    local label = itemLabel(transfer.name or transfer.item, transfer.count)
    game.choices(turn, 'before', {
        { id = 'yes', label = game.l10n('giveChoice', { item = label }) },
        { id = 'no', label = game.l10n('keepChoice') },
    }, function(choiceId)
        if choiceId ~= 'yes' then
            game.happened(turn, string.format('The stranger offered %s %s, but then thought better of it and kept it.',
                turn.npcName, label))
            game.continueTurn(turn)
            return
        end
        applyTransfer(game, turn, transfer, function(result, given, rewards, effects)
            if result.ok then
                -- This turn's exchange is settled: no after-reply checks
                turn.settled = true
                game.happened(turn, string.format('The stranger has just handed %s %s.', turn.npcName, given))
                if effects and effects.text then
                    game.happened(turn, string.format('In the original story, %s reacts like this: "%s"', turn.npcName,
                        game.expand(effects.text, turn.npc)))
                end
                if #rewards > 0 then
                    game.happened(turn, string.format('%s has given the stranger a reward: %s.', turn.npcName,
                        table.concat(rewards, ', ')))
                end
            end
            game.continueTurn(turn)
        end)
    end)
    return 'paused'
end

-- The NPC gives, in their reply: the player accepts or refuses
local function accept(game, turn, params)
    local transfer = params.transfer
    local label = itemLabel(transfer.name or transfer.item, transfer.count)
    game.choices(turn, 'after', {
        { id = 'yes', label = game.l10n('acceptChoice', { item = label }) },
        { id = 'no', label = game.l10n('refuseChoice') },
    }, function(choiceId)
        if choiceId ~= 'yes' then
            game.historyEvent(turn.npc, string.format('%s offered the stranger %s, but the stranger refused it.',
                turn.npcName, label))
            game.finishTurn()
            return
        end
        applyTransfer(game, turn, transfer, function()
            game.finishTurn()
        end)
    end)
end

M.intents = {
    {
        name = 'give',
        params = { 'item', 'count' },
        describe = function(ctx)
            return ctx.playerName .. ' hands one of their items or gold to ' .. ctx.npcName .. ' now ("here, take it", '
                .. '"have some gold", "here is the money you asked for").'
        end,
        available = function(ctx)
            return #ctx.candidates > 0
        end,
        parse = function(ctx, answer)
            local transfer = check.transfer(answer, ctx.candidates, check.PLAYER_GIVES)
            return transfer and { transfer = transfer, candidates = ctx.candidates } or nil
        end,
        run = give,
    },
}

M.proposals = {
    {
        name = 'give_item',
        params = { 'item', 'count' },
        describe = function(ctx)
            return ctx.npcName .. ' gives one of their own items or gold to ' .. ctx.playerName .. ' now, for example '
                .. 'paying ' .. ctx.playerName .. ' or handing over a reward. ' .. ctx.playerName .. ' giving something, '
                .. ctx.npcName .. ' holding out a hand to receive, asking for money, saying they have none, promises '
                .. 'and refusals do not count.'
        end,
        available = function(ctx)
            return #ctx.candidates > 0
        end,
        parse = function(ctx, answer)
            local transfer = check.transfer(answer, ctx.candidates, check.NPC_GIVES)
            return transfer and { transfer = transfer } or nil
        end,
        run = accept,
    },
}

return M
