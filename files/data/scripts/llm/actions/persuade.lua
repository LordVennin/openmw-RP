-- Persuasion by conversation: admiring, intimidating or taunting the NPC in the player's own words, resolved with
-- vanilla's formula (scripts/llm/persuasion.lua) and the player's stats. The model is told the outcome in words.

local core = require('openmw.core')
local I = require('openmw.interfaces')
local types = require('openmw.types')

local persuasion = require('scripts.llm.persuasion')

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
}

-- Vanilla persuasion for an admire/intimidate/taunt line; returns a line for the [What just happened] note
local function persuade(game, turn, kind)
    local npc = turn.npc
    local player = game.player
    local convo = game.conversation(npc)
    convo.attempts[kind] = (convo.attempts[kind] or 0) + 1
    if convo.attempts[kind] > persuasion.MAX_ATTEMPTS_PER_KIND then
        return string.format('The stranger keeps repeating the same approach; %s is tired of it and it has no effect.',
            turn.npcName)
    end
    local disposition = types.NPC.getDisposition(npc, player)
    local gmst = gmstValues()
    local result = persuasion.attempt(kind, persuasionStats(player), persuasionStats(npc), disposition,
        math.random(0, 99), gmst)
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
    local line = string.format(outcomes[kind][result.success], turn.npcName, turn.npcName)

    -- How close is the NPC to violence? The engine's own rule, with this attempt's changes included
    local dispositionAfter = math.min(disposition + result.temp, disposition + result.perm)
    local dx, dy = npc.position.x - player.position.x, npc.position.y - player.position.y
    local fight = types.Actor.stats.ai.fight(npc).modified + result.fight
    local term = persuasion.fightTerm(fight, math.sqrt(dx * dx + dy * dy), dispositionAfter, gmst)
    if term >= persuasion.ATTACK_THRESHOLD then
        turn.endReason = 'attack'
        line = line .. string.format(' %s loses their temper and attacks the stranger.', turn.npcName)
    elseif term >= persuasion.THREATENING_THRESHOLD then
        line = line .. string.format(' %s is barely holding back from violence and threatens the stranger.', turn.npcName)
    elseif dispositionAfter <= 20 then
        turn.endReason = 'fedUp'
        line = line .. string.format(' %s has had enough of the stranger and ends the conversation.', turn.npcName)
    end
    print(string.format('LLM persuasion: %s %s -> %s, temporary %+d, permanent %+d, fight %+d, fight term %d', kind,
        npc.recordId, result.success and 'success' or 'failure', result.temp, result.perm, result.fight, term))
    return line
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
