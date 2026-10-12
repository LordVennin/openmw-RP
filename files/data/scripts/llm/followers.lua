-- Decides whether an NPC agrees to follow the player when asked in an AI conversation. The game decides, the model
-- only voices it. Liking the player is one path to yes; fear and authority are others, because in Morrowind people
-- often follow those they dislike. NPCs whose movement belongs to a quest are never taken over.

local core = require('openmw.core')
local types = require('openmw.types')

local M = {}

M.WILLING_DISPOSITION = 70
M.WILLING_DISPOSITION_WITH_JOB = 85

local movementCommands = { 'aifollow', 'aiescort', 'aitravel' }

local function mentionsMovement(text)
    if not text then
        return false
    end
    local lower = text:lower()
    for _, command in ipairs(movementCommands) do
        if lower:find(command, 1, true) then
            return true
        end
    end
    return false
end

-- npc record id -> true for NPCs that vanilla dialogue moves with AiFollow/AiEscort/AiTravel; built on first use
local scriptedByDialogue = nil

local function buildDialogueIndex()
    scriptedByDialogue = {}
    for _, dialogueType in ipairs({ 'topic', 'greeting' }) do
        for _, record in pairs(core.dialogue[dialogueType].records) do
            for _, info in ipairs(record.infos) do
                if info.filterActorId and mentionsMovement(info.resultScript) then
                    scriptedByDialogue[info.filterActorId:lower()] = true
                end
            end
        end
    end
end

-- Whether a quest controls this NPC's movement (their own script or their vanilla dialogue moves them)
function M.isQuestControlled(npc)
    local record = types.NPC.record(npc)
    if record.mwscript and record.mwscript ~= '' then
        local script = core.mwscripts.records[record.mwscript]
        if script and mentionsMovement(script.text) then
            return true
        end
    end
    if not scriptedByDialogue then
        buildDialogueIndex()
    end
    return scriptedByDialogue[npc.recordId:lower()] == true
end

-- Whether the NPC has work that keeps them in place: services, or guard duty
function M.hasJob(npc)
    local record = types.NPC.record(npc)
    for _, offered in pairs(record.servicesOffered or {}) do
        if offered then
            return true
        end
    end
    return record.class and record.class:lower():find('guard', 1, true) ~= nil
end

-- Whether the player outranks the NPC in the NPC's faction
function M.outranks(player, npc)
    local ok, factions = pcall(types.NPC.getFactions, npc)
    for _, factionId in ipairs(ok and factions or {}) do
        local npcRank = types.NPC.getFactionRank(npc, factionId)
        local playerRank = types.NPC.getFactionRank(player, factionId)
        if playerRank > 0 and playerRank > npcRank and not types.NPC.isExpelled(player, factionId) then
            return true
        end
    end
    return false
end

-- The decision itself, from facts only (no game API, so it can be tested)
-- @param facts { questControlled, essential, coerced, outranks, disposition, hasJob }
-- @return { agrees = bool, reason = string }
function M.decide(facts)
    if facts.questControlled then
        return { agrees = false, reason = 'quest' }
    elseif facts.essential then
        return { agrees = false, reason = 'essential' }
    elseif facts.coerced then
        return { agrees = true, reason = 'afraid' }
    elseif facts.outranks then
        return { agrees = true, reason = 'rank' }
    end
    local needed = facts.hasJob and M.WILLING_DISPOSITION_WITH_JOB or M.WILLING_DISPOSITION
    if facts.disposition >= needed then
        return { agrees = true, reason = 'likes' }
    end
    if facts.hasJob and facts.disposition >= M.WILLING_DISPOSITION then
        return { agrees = false, reason = 'job' }
    end
    return { agrees = false, reason = 'dislikes' }
end

-- Gathers the facts for an NPC and decides
function M.decideFor(npc, player, coerced)
    local record = types.NPC.record(npc)
    return M.decide({
        questControlled = M.isQuestControlled(npc),
        essential = record.isEssential == true,
        coerced = coerced == true,
        outranks = M.outranks(player, npc),
        disposition = types.NPC.getDisposition(npc, player),
        hasJob = M.hasJob(npc),
    })
end

return M
