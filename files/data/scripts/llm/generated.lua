-- Builds a character card from game data for NPCs without a hand-written card. Small models stay in character
-- much better with a substantial card, so this combines the record, race, class and faction with short
-- speech-flavour hints, while keeping every source text to a sentence or two.

local core = require('openmw.core')
local types = require('openmw.types')

local budget = require('scripts.llm.budget')

local M = {}

-- How each race tends to talk; a short hint is more useful to a small model than the long in-game description.
local raceFlavour = {
    ['dark elf'] = 'Proud and wary of outsiders; may call foreigners "outlander" or, when insulted, "n\'wah", '
        .. 'and greets friends with "sera" or "muthsera".',
    ['high elf'] = 'Refined and condescending; believes in the superiority of Altmeri culture.',
    ['wood elf'] = 'Quick-witted and restless; speaks fast and informally.',
    ['imperial'] = 'Polite, formal and law-minded; loyal to the Empire and its Legion.',
    ['breton'] = 'Courteous and curious, with an interest in magic and learning.',
    ['nord'] = 'Blunt, hearty and plain-spoken; values strength and honesty.',
    ['redguard'] = 'Confident and direct; respects skill with a blade.',
    ['orc'] = 'Gruff and terse; values honour and hard work.',
    ['khajiit'] = 'Refers to themselves in the third person ("this one", or by name), and speaks with a sly, '
        .. 'purring politeness.',
    ['argonian'] = 'Speaks plainly and patiently, sometimes with odd phrasing; distrustful of Dunmer.',
}

local services = {
    { key = 'Barter', text = 'trades goods' },
    { key = 'Spells', text = 'sells spells' },
    { key = 'Training', text = 'offers training' },
    { key = 'Repair', text = 'repairs equipment' },
    { key = 'Enchanting', text = 'enchants items' },
    { key = 'Spellmaking', text = 'makes spells' },
    { key = 'Travel', text = 'arranges travel' },
}

local function firstSentences(text, count)
    if not text or text == '' then
        return nil
    end
    text = text:gsub('%s+', ' ')
    local result, n = '', 0
    for sentence in text:gmatch('[^%.!?]+[%.!?]+') do
        result = result .. sentence
        n = n + 1
        if n >= count then
            break
        end
    end
    result = result:gsub('^%s+', '')
    return result ~= '' and result or text
end

local function cellName(cell)
    if cell.name and cell.name ~= '' then
        return cell.name
    end
    local region = cell.region and core.regions.records[cell.region]
    return region and region.name ~= '' and region.name or 'Vvardenfell'
end

-- @param npc the NPC object
-- @param greeting the vanilla greeting text the NPC just said, if any
-- @return a card table in the same shape as cards.load
function M.build(npc, greeting)
    local record = types.NPC.record(npc)
    local race = types.NPC.races.record(record.race)
    local class = types.NPC.classes.record(record.class)
    local he = record.isMale and 'He' or 'She'
    local raceName = race and race.name or 'mer'
    local className = class and class.name or 'commoner'

    local lines = {}
    lines[#lines + 1] = string.format('%s is a %s %s %s, found in %s on the island of Vvardenfell.', record.name,
        record.isMale and 'male' or 'female', raceName, className:lower(), cellName(npc.cell))

    local ok, factions = pcall(types.NPC.getFactions, npc)
    for _, factionId in ipairs(ok and factions or {}) do
        local faction = core.factions.records[factionId]
        if faction and not faction.hidden then
            local rank = types.NPC.getFactionRank(npc, factionId)
            local rankName = faction.ranks[rank] and faction.ranks[rank].name
            if rankName and rankName ~= '' then
                lines[#lines + 1] = string.format('%s serves the %s, holding the rank of %s.', he, faction.name,
                    rankName)
            else
                lines[#lines + 1] = string.format('%s belongs to the %s.', he, faction.name)
            end
        end
    end

    local offered = {}
    if record.servicesOffered then
        for _, service in ipairs(services) do
            if record.servicesOffered[service.key] then
                offered[#offered + 1] = service.text
            end
        end
    end
    if #offered > 0 then
        lines[#lines + 1] = he .. ' ' .. table.concat(offered, ', ') .. '.'
    end

    local classText = class and firstSentences(class.description, 1)
    if classText then
        lines[#lines + 1] = 'About ' .. className:lower() .. 's: ' .. classText
    end
    local raceText = race and firstSentences(race.description, 2)
    if raceText then
        lines[#lines + 1] = 'About the ' .. raceName .. ' people: ' .. raceText
    end

    local personality = raceFlavour[raceName:lower()] or 'Speaks according to their station and upbringing.'
    personality = personality .. ' Has their own opinions, goals and worries, and talks like an ordinary person '
        .. 'of Vvardenfell, not like a guide.'

    return {
        name = record.name,
        description = table.concat(lines, ' '),
        personality = personality,
        scenario = string.format('%s is in %s when a stranger approaches to talk.', record.name, cellName(npc.cell)),
        firstMes = greeting,
    }
end

-- Shortens a card so it fits its token share
function M.fit(card, tokens)
    local result = {}
    for key, value in pairs(card) do
        result[key] = value
    end
    if result.description then
        result.description = budget.truncate(result.description, math.floor(tokens * 0.7))
    end
    if result.mesExample then
        result.mesExample = budget.truncate(result.mesExample, math.floor(tokens * 0.2))
    end
    return result
end

return M
