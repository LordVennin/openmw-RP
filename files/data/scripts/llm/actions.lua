-- Decides whether an item changed hands in the last exchange of an AI conversation. The roleplay reply stays free
-- prose; afterwards, only when an item is mentioned, a short second request asks the model to classify the
-- exchange. Its output is constrained by a JSON schema that only allows items actually in the giver's inventory.
-- This module only builds and parses requests; the move itself happens in scripts/llm/global.lua.

local M = {}

local GOLD_ID = 'gold_001'
local MAX_ITEM_COUNT = 10
local MAX_GOLD = 1000

-- Words too common in item names to count as a mention on their own
local stopWords = {
    the = true, ['of'] = true, ['and'] = true, a = true, an = true, ['with'] = true, ['for'] = true,
    common = true, expensive = true, extravagant = true, exquisite = true, cheap = true, small = true,
    large = true, old = true, new = true, iron = true, steel = true,
}

local coinWords = { 'gold', 'coin', 'coins', 'drake', 'drakes', 'septim', 'septims', 'money', 'pay', 'paid' }

local function words(text)
    local result = {}
    for word in text:lower():gmatch('[%a\'%-]+') do
        if #word >= 3 and not stopWords[word] then
            result[#result + 1] = word
        end
    end
    return result
end

local function containsWord(haystack, word)
    return haystack:find('%f[%w]' .. word:gsub('[%-]', '%%-') .. '%f[%W]') ~= nil
end

-- How many significant words of `name` appear in `haystack` (already lower-cased)
local function mentionScore(name, haystack)
    local score = 0
    for _, word in ipairs(words(name)) do
        if containsWord(haystack, word) then
            score = score + 1
        end
    end
    return score
end

-- @param texts strings from the last exchange (the player's line and the NPC's reply)
-- @param playerItems, npcItems lists of { id = record id, name = display name, count = total count }
-- @return candidates: list of { id, name, playerCount, npcCount }, best mentions first; empty if nothing fits
function M.findCandidates(texts, playerItems, npcItems, limit)
    local haystack = table.concat(texts, '\n'):lower()
    local byId = {}
    local function add(item, side)
        local entry = byId[item.id]
        if not entry then
            entry = { id = item.id, name = item.name, playerCount = 0, npcCount = 0, score = 0 }
            byId[item.id] = entry
        end
        entry[side] = entry[side] + item.count
    end
    for _, item in ipairs(playerItems) do
        add(item, 'playerCount')
    end
    for _, item in ipairs(npcItems) do
        add(item, 'npcCount')
    end

    local mentionsCoin = false
    for _, word in ipairs(coinWords) do
        if containsWord(haystack, word) then
            mentionsCoin = true
            break
        end
    end

    local candidates = {}
    for id, entry in pairs(byId) do
        if id == GOLD_ID then
            entry.score = mentionsCoin and 100 or 0
        elseif entry.name and entry.name ~= '' then
            entry.score = mentionScore(entry.name, haystack)
        end
        if entry.score > 0 then
            candidates[#candidates + 1] = entry
        end
    end
    table.sort(candidates, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        return a.id < b.id
    end)
    while #candidates > (limit or 8) do
        table.remove(candidates)
    end
    return candidates
end

local function maxCount(candidates)
    local max = 1
    for _, c in ipairs(candidates) do
        local cap = c.id == GOLD_ID and MAX_GOLD or MAX_ITEM_COUNT
        max = math.max(max, math.min(cap, math.max(c.playerCount, c.npcCount)))
    end
    return max
end

-- JSON schema for the classification. The enums are the only values the model can produce.
function M.schema(candidates)
    local ids = { 'none' }
    for _, c in ipairs(candidates) do
        ids[#ids + 1] = c.id
    end
    return {
        type = 'object',
        properties = {
            transfer = { enum = { 'none', 'player_to_npc', 'npc_to_player' } },
            item = { enum = ids },
            count = { type = 'integer', minimum = 0, maximum = maxCount(candidates) },
        },
        required = { 'transfer', 'item', 'count' },
    }
end

-- The classification prompt, in the active instruct template
-- @param exchange list of { speaker = name, text = string }, oldest first (the last exchange or two)
function M.prompt(template, npcName, playerName, exchange, candidates)
    local system = 'You are the game master of a Morrowind role-play. Decide whether an item or gold changed hands '
        .. 'in the latest exchange between ' .. playerName .. ' and ' .. npcName .. '. Count it only if the giver '
        .. 'clearly hands it over in this exchange and the receiver accepts it. Offers, promises, haggling, '
        .. 'refusals and things that happened earlier do not count. Answer with JSON only.'

    local lines = { 'Conversation:' }
    for _, turn in ipairs(exchange) do
        lines[#lines + 1] = turn.speaker .. ': ' .. turn.text
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Items that could be involved (id - name - who has how many):'
    for _, c in ipairs(candidates) do
        lines[#lines + 1] = string.format('%s - %s - %s has %d, %s has %d', c.id, c.name or c.id, playerName,
            c.playerCount, npcName, c.npcCount)
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Answer as {"transfer": "none" | "player_to_npc" | "npc_to_player", "item": item id or '
        .. '"none", "count": number of items or gold pieces}. "player_to_npc" means ' .. playerName .. ' gave it to '
        .. npcName .. '.'

    return template.systemPrefix .. system .. template.systemSuffix
        .. template.userPrefix .. table.concat(lines, '\n') .. template.userSuffix
        .. template.modelPrefix .. (template.replyPrefix or '')
end

-- Checks the model's answer against the candidates and the giver's inventory.
-- @return { transfer, item, name, count } or nil when nothing should happen
function M.parse(answer, candidates)
    if type(answer) ~= 'table' or answer.transfer == 'none' or answer.item == 'none' then
        return nil
    end
    if answer.transfer ~= 'player_to_npc' and answer.transfer ~= 'npc_to_player' then
        return nil
    end
    local count = math.floor(tonumber(answer.count) or 0)
    if count <= 0 then
        return nil
    end
    for _, c in ipairs(candidates) do
        if c.id == answer.item then
            local available = answer.transfer == 'player_to_npc' and c.playerCount or c.npcCount
            local cap = c.id == GOLD_ID and MAX_GOLD or MAX_ITEM_COUNT
            count = math.min(count, available, cap)
            if count <= 0 then
                return nil
            end
            return { transfer = answer.transfer, item = c.id, name = c.name, count = count }
        end
    end
    return nil
end

M.GOLD_ID = GOLD_ID

return M
