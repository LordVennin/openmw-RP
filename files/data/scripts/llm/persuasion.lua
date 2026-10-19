-- Vanilla persuasion (Admire, Intimidate, Taunt) for AI conversations, ported from
-- MWMechanics::MechanicsManager::getPersuasionDispositionChange (apps/openmw/mwmechanics/mechanicsmanagerimp.cpp).
-- The model only classifies what the player said; whether it works, and by how much, comes from the player's and
-- the NPC's stats exactly as in vanilla. Pure functions: callers pass stats, GMSTs and the dice roll.

local M = {}

M.TYPES = { admire = 'admire', intimidate = 'intimidate', taunt = 'taunt', bribe = 'bribe' }

-- Vanilla values from Morrowind.esm, used when a GMST can't be read
M.DEFAULT_GMST = {
    fPersonalityMod = 5,
    fLuckMod = 10,
    fReputationMod = 1,
    fLevelMod = 5,
    fPerDieRollMult = 0.3,
    fPerTempMult = 1,
    iPerMinChance = 5,
    iPerMinChange = 10,
    fFatigueBase = 1.25,
    fFatigueMult = 0.5,
    fFightDispMult = 0.2,
    iFightDistanceBase = 20,
    fFightDistanceMultiplier = 0.005,
    fBribe10Mod = 35,
    fBribe100Mod = 75,
    fBribe1000Mod = 150,
}

-- C++ int() truncates toward zero
local function trunc(x)
    return x >= 0 and math.floor(x) or math.ceil(x)
end

-- CreatureStats::getFatigueTerm
function M.fatigueTerm(stats, g)
    local max = stats.fatigueMax or 0
    local normalised = math.floor(max) == 0 and 1 or math.max(0, (stats.fatigueCurrent or 0) / max)
    return g.fFatigueBase - g.fFatigueMult * (1 - normalised)
end

-- getPersuasionRatings: rating1, rating2, and rating3 (only used for bribes)
-- @param stats { speechcraft, mercantile, personality, luck, reputation, level, fatigueCurrent, fatigueMax }
function M.ratings(stats, isPlayer, g)
    local persTerm = stats.personality / g.fPersonalityMod
    local luckTerm = stats.luck / g.fLuckMod
    local repTerm = stats.reputation * g.fReputationMod
    local fatigue = M.fatigueTerm(stats, g)
    local levelTerm = stats.level * g.fLevelMod
    local rating1 = (repTerm + luckTerm + persTerm + stats.speechcraft) * fatigue
    local rating2, rating3
    local mercantile = stats.mercantile or 0
    if isPlayer then
        rating2 = rating1 + levelTerm
        rating3 = (mercantile + luckTerm + persTerm) * fatigue
    else
        rating2 = (levelTerm + repTerm + luckTerm + persTerm + stats.speechcraft) * fatigue
        rating3 = (mercantile + repTerm + luckTerm + persTerm) * fatigue
    end
    return rating1, rating2, rating3
end

-- The bribe bonus for any amount. Vanilla only offers 10, 100 and 1000 gold (fBribe10Mod, fBribe100Mod,
-- fBribe1000Mod); other amounts are interpolated on a log scale between those, scaled down linearly below 10 and
-- capped at 1000, so the three vanilla amounts give exactly vanilla's result.
function M.bribeMod(amount, gmst)
    local g = gmst or M.DEFAULT_GMST
    if amount <= 0 then
        return 0
    elseif amount < 10 then
        return g.fBribe10Mod * amount / 10
    elseif amount >= 1000 then
        return g.fBribe1000Mod
    end
    local scale = math.log10(amount)
    if scale <= 2 then
        return g.fBribe10Mod + (g.fBribe100Mod - g.fBribe10Mod) * (scale - 1)
    end
    return g.fBribe100Mod + (g.fBribe1000Mod - g.fBribe100Mod) * (scale - 2)
end

-- @param kind M.TYPES value
-- @param disposition the NPC's current (derived) disposition, 0-100
-- @param roll 0-99
-- @param amount gold offered, for bribes
-- @return { success = bool, temp = int, perm = int, fight = int, flee = int }: temp applies during the conversation,
--         perm afterwards; fight and flee are the changes to the NPC's AI ratings (vanilla Taunt and Intimidate)
function M.attempt(kind, playerStats, npcStats, disposition, roll, gmst, amount)
    local g = gmst or M.DEFAULT_GMST
    local npc1, npc2, npc3 = M.ratings(npcStats, false, g)
    local pl1, pl2, pl3 = M.ratings(playerStats, true, g)

    local d = 1 - 0.02 * math.abs(disposition - 50)
    local target1 = d * (pl1 - npc1 + 50)
    local target2 = d * (pl2 - npc2 + 50)
    local minChance, minChange = g.iPerMinChance, g.iPerMinChange
    local dieMult, tempMult = g.fPerDieRollMult, g.fPerTempMult

    local success, x, y = false, 0, 0
    local fight, flee = 0, 0
    if kind == M.TYPES.admire then
        target1 = math.max(minChance, target1)
        success = roll <= target1
        local c = math.floor(dieMult * (target1 - roll))
        x = success and math.max(minChange, c) or c
    elseif kind == M.TYPES.intimidate then
        target2 = math.max(minChance, target2)
        success = roll <= target2
        local r = roll ~= target2 and math.floor(target2 - roll) or 1
        if success then
            -- Scared: more likely to flee, less likely to fight
            local s = math.floor(r * dieMult * tempMult)
            flee = trunc(math.max(minChange, s))
            fight = trunc(math.min(-minChange, -s))
        end
        local c = -math.abs(math.floor(r * dieMult))
        if success then
            if math.abs(c) < minChange then
                x = minChange -- OpenMW's fix for marginal wins
                y = x
            else
                x = -math.floor(c * tempMult)
                y = c
            end
        else
            x = math.floor(c * tempMult)
            y = c
        end
    elseif kind == M.TYPES.taunt then
        target1 = math.max(minChance, target1)
        success = roll <= target1
        local c = math.abs(math.floor(target1 - roll))
        if success then
            -- Provoked: more likely to fight, less likely to flee
            local s = c * dieMult * tempMult
            flee = math.min(-trunc(minChange), trunc(-s))
            fight = math.max(trunc(minChange), trunc(s))
        end
        x = math.floor(-c * dieMult)
        if success and math.abs(x) < minChange then
            x = -minChange
        end
    elseif kind == M.TYPES.bribe then
        local target3 = math.max(minChance, d * (pl3 - npc3 + 50) + M.bribeMod(amount or 0, g))
        success = roll <= target3
        local c = math.floor((target3 - roll) * dieMult)
        x = success and math.max(minChange, c) or c
    else
        error('unknown persuasion type ' .. tostring(kind))
    end

    local temp, perm
    if kind == M.TYPES.intimidate then
        temp = trunc(x)
    else
        temp = trunc(x * tempMult)
    end
    if disposition + temp > 100 then
        temp = 100 - disposition
    elseif disposition + temp < 0 then
        temp = -disposition
    end
    if kind == M.TYPES.intimidate then
        perm = success and -trunc(temp / tempMult) or trunc(y)
    else
        perm = trunc(temp / tempMult)
    end
    return { success = success, temp = temp, perm = perm, fight = fight, flee = flee }
end

-- How likely the stranger's way with words keeps an upset NPC talking, in percent: vanilla's persuasion rating1
-- (Speechcraft, Personality, Luck, Reputation, fatigue) against the NPC's, as for admire but without the disposition
-- factor, since the NPC is already angry. Vanilla never ends a conversation, so this is the mod's own rule.
function M.patienceChance(playerStats, npcStats, gmst)
    local g = gmst or M.DEFAULT_GMST
    local player1 = M.ratings(playerStats, true, g)
    local npc1 = M.ratings(npcStats, false, g)
    return math.max(g.iPerMinChance, math.min(95, player1 - npc1 + 50))
end

-- The engine's aggression rule (getFightTerm in apps/openmw/mwmechanics/combat.cpp): at 100 or more the NPC attacks.
-- @param fight the NPC's Fight rating (modified)
-- @param distance distance to the player in game units
-- @param disposition the NPC's derived disposition
function M.fightTerm(fight, distance, disposition, gmst)
    local g = gmst or M.DEFAULT_GMST
    local distanceBias = g.iFightDistanceBase - g.fFightDistanceMultiplier * distance
    local dispositionBias = (50 - disposition) * g.fFightDispMult
    return fight + trunc(distanceBias + dispositionBias)
end

M.ATTACK_THRESHOLD = 100
M.THREATENING_THRESHOLD = 80

-- Repeating the same kind of attempt in one conversation stops working, so flattery can't be spammed
M.MAX_ATTEMPTS_PER_KIND = 2

return M
