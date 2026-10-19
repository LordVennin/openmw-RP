-- Persuasion by conversation: admiring, intimidating or taunting the NPC in the player's own words, resolved with
-- vanilla's formula (scripts/llm/persuasion.lua) and the player's stats. The model is told the outcome in words.

local core = require('openmw.core')
local I = require('openmw.interfaces')
local types = require('openmw.types')

local persuasion = require('scripts.llm.persuasion')
local check = require('scripts.llm.actions.check')
local give = require('scripts.llm.actions.give')

local M = {}

local function gmstValues()
    local values = {}
    for key, default in pairs(persuasion.DEFAULT_GMST) do
        local ok, value = pcall(core.getGMST, key)
        values[key] = (ok and type(value) == 'number') and value or default
    end
    return values
end

local function persuasionStats(actor)
    local fatigue = types.Actor.stats.dynamic.fatigue(actor)
    return {
        speechcraft = types.NPC.stats.skills.speechcraft(actor).modified,
        mercantile = types.NPC.stats.skills.mercantile(actor).modified,
        personality = types.Actor.stats.attributes.personality(actor).modified,
        luck = types.Actor.stats.attributes.luck(actor).modified,
        reputation = types.NPC.stats.reputation(actor).current,
        level = types.Actor.stats.level(actor).current,
        fatigueCurrent = fatigue.current,
        fatigueMax = fatigue.base,
    }
end

-- Plain-words outcome lines for the model; no numbers
local outcomes = {
    admire = {
        [true] = "The stranger's words flattered %s, and it worked: %s warms to the stranger.",
        [false] = "The stranger tried to flatter %s, but it fell flat: %s is unimpressed.",
    },
    intimidate = {
        [true] = "The stranger's threat worked: %s is afraid of the stranger and will do as told, but resents it.",
        [false] = "The stranger tried to intimidate %s, but it failed: %s is not scared, only annoyed.",
    },
    taunt = {
        [true] = "The stranger's insult struck home: %s is angry and hurt.",
        [false] = "%s shrugs off the stranger's insult, but thinks less of the stranger.",
    },
    -- %s is the NPC's name, then the amount offered
    bribe = {
        [true] = 'The stranger offered %s %s as a bribe, and it worked: %s accepts it and warms to the stranger.',
        [false] = 'The stranger offered %s %s as a bribe, but %s refuses it and thinks less of the stranger for '
            .. 'offering it.',
    },
}

-- Vanilla persuasion for an admire/intimidate/taunt line, or a bribe of `offer.label` (`offer.count` gold).
-- Returns a line for the [What just happened] note, and whether it succeeded.
local function persuade(game, turn, kind, offer)
    local npc = turn.npc
    local player = game.player
    local convo = game.conversation(npc)
    convo.attempts[kind] = (convo.attempts[kind] or 0) + 1
    -- Like vanilla, bribes can be repeated: the gold is their limit
    if kind ~= persuasion.TYPES.bribe and convo.attempts[kind] > persuasion.MAX_ATTEMPTS_PER_KIND then
        return string.format('The stranger keeps repeating the same approach; %s is tired of it and it has no effect.',
            turn.npcName), false
    end
    local disposition = types.NPC.getDisposition(npc, player)
    local gmst = gmstValues()
    local playerStats, npcStats = persuasionStats(player), persuasionStats(npc)
    local result = persuasion.attempt(kind, playerStats, npcStats, disposition, math.random(0, 99), gmst,
        offer and offer.count)
    if not convo.originalBase then
        convo.originalBase = types.NPC.getBaseDisposition(npc, player)
    end
    convo.permanent = convo.permanent + result.perm
    if result.temp ~= 0 then
        game.sendGlobal('LLMModDisposition', { npc = npc, player = player, delta = result.temp })
    end
    if kind == persuasion.TYPES.intimidate and result.success then
        convo.coerced = true
    end
    if kind == persuasion.TYPES.taunt or (kind == persuasion.TYPES.intimidate and not result.success) then
        convo.upset = true
    end
    if result.fight ~= 0 or result.flee ~= 0 then
        game.sendGlobal('LLMModAI', { npc = npc, fight = result.fight, flee = result.flee })
    end
    local useTypes = I.SkillProgression.SKILL_USE_TYPES
    I.SkillProgression.skillUsed('speechcraft',
        { useType = result.success and useTypes.Speechcraft_Success or useTypes.Speechcraft_Fail })
    local line
    if offer then
        line = string.format(outcomes.bribe[result.success], turn.npcName, offer.label, turn.npcName)
    else
        line = string.format(outcomes[kind][result.success], turn.npcName, turn.npcName)
    end

    -- How close is the NPC to violence? The engine's own rule, with this attempt's changes included
    local dispositionAfter = math.min(disposition + result.temp, disposition + result.perm)
    local dx, dy = npc.position.x - player.position.x, npc.position.y - player.position.y
    local fight = types.Actor.stats.ai.fight(npc).modified + result.fight
    local term = persuasion.fightTerm(fight, math.sqrt(dx * dx + dy * dy), dispositionAfter, gmst)
    if term >= persuasion.ATTACK_THRESHOLD then
        turn.endReason = 'attack'
        line = line .. string.format(' %s loses their temper and will attack the stranger once they stop talking: '
            .. 'a few furious words only, the fight itself happens in the game.', turn.npcName)
    elseif term >= persuasion.THREATENING_THRESHOLD then
        line = line .. string.format(' %s is barely holding back from violence and threatens the stranger, in words.',
            turn.npcName)
    elseif dispositionAfter <= 20 then
        -- Fed up: a smooth talker may still keep them in the conversation (this is the turn's patience roll)
        turn.patienceRolled = true
        if math.random(0, 99) < persuasion.patienceChance(playerStats, npcStats, gmst) then
            turn.patient = true
            line = line .. string.format(" %s has nearly had enough of the stranger, but the stranger's way with words "
                .. 'keeps them talking, for now.', turn.npcName)
        else
            turn.endReason = 'fedUp'
            line = line .. string.format(' %s has had enough of the stranger and ends the conversation.', turn.npcName)
        end
    end
    if kind == persuasion.TYPES.taunt then
        -- Insults make the model narrate scuffles; the game plays out any fight itself
        line = line .. string.format(' %s answers with words and small gestures of their own: they do not touch, grab '
            .. 'or strike the stranger, and do not describe what the stranger does.', turn.npcName)
    end
    print(string.format('LLM persuasion: %s %s -> %s, temporary %+d, permanent %+d, fight %+d, fight term %d', kind,
        npc.recordId, result.success and 'success' or 'failure', result.temp, result.perm, result.fight, term))
    return line, result.success
end

-- A bribe the player chose to make (scripts/llm/actions/give.lua offers it): roll with vanilla's bribe formula, and
-- hand over the gold only if it worked
function M.bribe(game, turn, transfer, label)
    local ok, line, success = pcall(persuade, game, turn, persuasion.TYPES.bribe,
        { count = transfer.count, label = label })
    if not ok then
        print('LLM bribe: ' .. tostring(line))
        game.continueTurn(turn)
        return
    end
    game.happened(turn, line)
    -- This turn's exchange is settled: no after-reply checks for the gold
    turn.settled = true
    if not success then
        game.historyEvent(turn.npc, string.format('The stranger tried to bribe %s with %s, but %s refused.',
            turn.npcName, label, turn.npcName))
        game.continueTurn(turn)
        return
    end
    give.applyTransfer(game, turn, transfer, function()
        game.continueTurn(turn)
    end, {
        noQuestEffects = true,
        event = string.format('The stranger bribed %s with %s.', turn.npcName, label),
    })
end

-- Whether an upset NPC stays in the conversation this turn, rolled with the player's Speechcraft and Personality
-- (persuasion.patienceChance)
function M.keepsTalking(game, npc)
    local chance = persuasion.patienceChance(persuasionStats(game.player), persuasionStats(npc), gmstValues())
    local roll = math.random(0, 99)
    print(string.format('LLM patience: %s, chance %d, roll %d', npc.recordId, chance, roll))
    return roll < chance
end

local function entry(kind, describe)
    return {
        name = kind,
        describe = describe,
        run = function(game, turn)
            local ok, line = pcall(persuade, game, turn, kind)
            if ok then
                game.happened(turn, line)
            else
                print('LLM persuasion: ' .. tostring(line))
            end
        end,
    }
end

M.intents = {
    {
        name = 'bribe',
        params = { 'item', 'count' },
        describe = function(ctx)
            return ctx.playerName .. ' hands over or offers ' .. ctx.npcName .. ' gold as a bribe, to win their '
                .. 'favour or to buy their help, information or silence ("keep this between us", "take this and forget '
                .. 'you saw me", "I\'ll pay you if you tell me"). Paying a price or a debt is give, and asking how much '
                .. 'it would take is none.'
        end,
        available = function(ctx)
            for _, c in ipairs(ctx.candidates) do
                if c.id == check.GOLD_ID and c.playerCount > 0 then
                    return true
                end
            end
            return false
        end,
        parse = function(ctx, answer)
            -- Only gold; without an amount, the smallest vanilla bribe
            local count = math.floor(tonumber(answer.count) or 0)
            local transfer = check.transfer({ item = check.GOLD_ID, count = count > 0 and count or 10 }, ctx.candidates,
                check.PLAYER_GIVES)
            return transfer and { transfer = transfer } or nil
        end,
        run = function(game, turn, params)
            return give.offer(game, turn, params, true)
        end,
    },
    entry('admire', function(ctx)
        return ctx.playerName .. ' flatters or compliments ' .. ctx.npcName .. ' (a plain question is not flattery).'
    end),
    entry('intimidate', function(ctx)
        return ctx.playerName .. ' threatens ' .. ctx.npcName .. ', menaces them, or pulls rank to force them.'
    end),
    entry('taunt', function(ctx)
        return ctx.playerName .. ' insults or mocks ' .. ctx.npcName .. '.'
    end),
}

return M
