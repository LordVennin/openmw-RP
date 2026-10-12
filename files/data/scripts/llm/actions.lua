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

-- Each check has a fixed direction: the offer check (before the reply) only looks for the player giving, the action
-- check (after the reply) only for the NPC giving. The model doesn't answer yes or no; it quotes the words that hand
-- something over ("evidence"), or "none". Small models quote reliably but are unreliable at the final yes/no, so the
-- decision is made here from the quote, which must also really appear in the line being judged.
M.PLAYER_GIVES = 'player_to_npc'
M.NPC_GIVES = 'npc_to_player'

local MAX_EVIDENCE_LENGTH = 160

-- JSON schema for a check, as a table (for tests). The item enum is the only set of ids the model can produce.
function M.schema(candidates)
    local ids = { 'none' }
    for _, c in ipairs(candidates) do
        ids[#ids + 1] = c.id
    end
    return {
        type = 'object',
        properties = {
            evidence = { type = 'string', maxLength = MAX_EVIDENCE_LENGTH },
            item = { enum = ids },
            count = { type = 'integer', minimum = 0, maximum = maxCount(candidates) },
        },
        required = { 'evidence', 'item', 'count' },
    }
end

local function promptText(template, system, lines)
    return template.systemPrefix .. system .. template.systemSuffix
        .. template.userPrefix .. table.concat(lines, '\n') .. template.userSuffix
        .. template.modelPrefix .. (template.replyPrefix or '')
end

-- The action check, after the reply: does the NPC give the player one of their own items or gold?
-- @param exchange list of { speaker = name, text = string }, oldest first (the last exchange)
function M.prompt(template, npcName, playerName, exchange, candidates)
    local system = 'You are the game master of a Morrowind role-play. Decide whether ' .. npcName .. ' gives one of '
        .. 'their own items or gold to ' .. playerName .. ' in ' .. npcName .. '\'s latest reply, for example paying '
        .. playerName .. ' or handing over a reward. Only ' .. npcName .. ' giving counts: ' .. playerName .. ' giving '
        .. 'something, ' .. npcName .. ' holding out a hand to receive, asking for money, saying they have none, '
        .. 'promises and refusals do not count. Answer with JSON only.'
    local lines = { 'Conversation:' }
    for _, turn in ipairs(exchange) do
        lines[#lines + 1] = turn.speaker .. ': ' .. turn.text
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Items ' .. npcName .. ' carries that could be involved (id - name - count):'
    for _, c in ipairs(candidates) do
        lines[#lines + 1] = string.format('%s - %s - %d', c.id, c.name or c.id, c.npcCount)
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Answer as {"evidence": the exact words from ' .. npcName .. '\'s latest reply where ' .. npcName
        .. ' hands the item or gold to ' .. playerName .. ', or "none" if there are no such words, "item": item id or '
        .. '"none", "count": number}.'
    return promptText(template, system, lines)
end

-- The offer check, before the reply: does the player hand one of their items or gold to the NPC in this line?
-- Doing this first lets the reply react to the handover (and to the vanilla quest reaction and rewards).
-- @param npcLastLine what the NPC said just before (for amounts like "the money you need"), or nil
function M.offerPrompt(template, npcName, playerName, userLine, candidates, npcLastLine)
    local system = 'You are the game master of a Morrowind role-play. Decide whether ' .. playerName .. ' gives, '
        .. 'or is giving, one of their items or gold to ' .. npcName .. ' in their latest line, for example '
        .. '"here, take it", "have some gold" or "here is the money you asked for". Saying "I could give you..." or '
        .. '"let me give you..." while reaching for or handing over the item also counts. Questions, refusals, '
        .. 'haggling and offers with a condition ("if you...") do not count. Answer with JSON only.'
    local lines = {}
    if npcLastLine and npcLastLine ~= '' then
        lines[#lines + 1] = npcName .. ' (just before): ' .. npcLastLine
    end
    lines[#lines + 1] = playerName .. ': ' .. userLine
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Items ' .. playerName .. ' carries that could be involved (id - name - count):'
    for _, c in ipairs(candidates) do
        lines[#lines + 1] = string.format('%s - %s - %d', c.id, c.name or c.id, c.playerCount)
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Answer as {"evidence": the exact words from ' .. playerName .. '\'s latest line where '
        .. playerName .. ' hands the item or gold over, or "none" if there are no such words, "item": item id or '
        .. '"none", "count": number}. For "count", use the amount named in the conversation (for example a price '
        .. npcName .. ' asked for); only if no amount was named, use 1 for items.'
    return promptText(template, system, lines)
end

local function jsonString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return string.format('\\u%04x', c:byte())
    end) .. '"'
end

-- The schema as JSON text with a fixed property order: the model writes the evidence first, then the item and count.
function M.schemaJson(candidates)
    local schema = M.schema(candidates)
    local quoted = {}
    for i, v in ipairs(schema.properties.item.enum) do
        quoted[i] = jsonString(v)
    end
    return string.format('{"type":"object","properties":{"evidence":{"type":"string","maxLength":%d},'
        .. '"item":{"enum":[%s]},"count":{"type":"integer","minimum":0,"maximum":%d}},'
        .. '"required":["evidence","item","count"]}', MAX_EVIDENCE_LENGTH, table.concat(quoted, ','),
        schema.properties.count.maximum)
end

-- Encodes a check's request body with the schema spliced in, keeping its property order
function M.encodeRequest(json, body, schemaText)
    local text = json.encode(body)
    return text:sub(1, -2) .. ',"json_schema":' .. schemaText .. '}'
end

local function normalize(text)
    return ' ' .. text:lower():gsub('[^%w]+', ' '):gsub('^ +', ''):gsub(' +$', '') .. ' '
end

-- Whether the quoted evidence really appears in the judged text (exactly, or at least most of its words)
function M.evidenceFound(evidence, text)
    if type(evidence) ~= 'string' then
        return false
    end
    local quote = normalize(evidence)
    if quote == '  ' or quote == ' none ' then
        return false
    end
    local haystack = normalize(text)
    if haystack:find(quote, 1, true) then
        return true
    end
    local words, found = 0, 0
    for word in quote:gmatch('%S+') do
        if #word >= 2 then
            words = words + 1
            if haystack:find(' ' .. word .. ' ', 1, true) then
                found = found + 1
            end
        end
    end
    return words > 0 and found / words >= 0.6
end

-- Turns a check's answer into a transfer, after checking it against the candidates and the giver's inventory.
-- @param direction M.PLAYER_GIVES or M.NPC_GIVES (fixed per check)
-- @param judgedText the line the evidence must come from (the player's line, or the NPC's reply)
-- @return { transfer, item, name, count } or nil when nothing should happen
function M.parse(answer, candidates, direction, judgedText)
    if type(answer) ~= 'table' or answer.item == 'none' or not M.evidenceFound(answer.evidence, judgedText or '') then
        return nil
    end
    local count = math.floor(tonumber(answer.count) or 0)
    if count <= 0 then
        return nil
    end
    for _, c in ipairs(candidates) do
        if c.id == answer.item then
            local available = direction == M.PLAYER_GIVES and c.playerCount or c.npcCount
            local cap = c.id == GOLD_ID and MAX_GOLD or MAX_ITEM_COUNT
            count = math.min(count, available, cap)
            if count <= 0 then
                return nil
            end
            return { transfer = direction, item = c.id, name = c.name, count = count }
        end
    end
    return nil
end

M.GOLD_ID = GOLD_ID

return M
