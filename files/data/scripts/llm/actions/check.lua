-- Shared helpers for the classification checks that decide what happens in a conversation. The roleplay reply stays
-- free prose; short separate requests ask the model what a line does, constrained by a JSON schema. The model doesn't
-- answer yes or no: it quotes the words that show the action ("evidence"), or "none". Small models quote reliably but
-- are unreliable at a final yes/no, so the decision is made here from the quote, which must really appear in the
-- line being judged.

local M = {}

local GOLD_ID = 'gold_001'
local MAX_ITEM_COUNT = 10
local MAX_GOLD = 1000
M.MAX_EVIDENCE_LENGTH = 160

-- Who gives in an item transfer
M.PLAYER_GIVES = 'player_to_npc'
M.NPC_GIVES = 'npc_to_player'
M.GOLD_ID = GOLD_ID

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
M.containsWord = containsWord

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

-- The largest count a check may answer for these candidates
function M.maxCount(candidates)
    local max = 1
    for _, c in ipairs(candidates) do
        local cap = c.id == GOLD_ID and MAX_GOLD or MAX_ITEM_COUNT
        max = math.max(max, math.min(cap, math.max(c.playerCount, c.npcCount)))
    end
    return max
end

function M.promptText(template, system, lines)
    return template.systemPrefix .. system .. template.systemSuffix
        .. template.userPrefix .. table.concat(lines, '\n') .. template.userSuffix
        .. template.modelPrefix .. (template.replyPrefix or '')
end

function M.jsonString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return string.format('\\u%04x', c:byte())
    end) .. '"'
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
    local count, found = 0, 0
    for word in quote:gmatch('%S+') do
        if #word >= 2 then
            count = count + 1
            if haystack:find(' ' .. word .. ' ', 1, true) then
                found = found + 1
            end
        end
    end
    return count > 0 and found / count >= 0.6
end

-- Turns a check's item and count into a transfer, after checking them against the candidates and the giver's
-- inventory. The evidence was already checked.
-- @param direction M.PLAYER_GIVES or M.NPC_GIVES
-- @return { transfer, item, name, count } or nil when nothing should happen
function M.transfer(answer, candidates, direction)
    if type(answer) ~= 'table' or answer.item == 'none' then
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

-- Does the NPC's reply end the conversation? Only asked while the NPC is upset, so friendly NPCs never walk off
-- because of a flourish in the reply. The answer is a quote, checked against the reply like the other checks.
function M.leavePrompt(template, npcName, playerName, reply)
    local system = 'You are the game master of a Morrowind role-play. Decide whether ' .. npcName .. ' ends the '
        .. 'conversation with ' .. playerName .. ' in their latest reply: walks away, turns their back, refuses to '
        .. 'talk any more, or tells ' .. playerName .. ' to leave. Actions written in asterisks count too, for '
        .. 'example *walks away*. Being annoyed, rude or busy while still talking does not count. Answer with JSON only.'
    local lines = {
        npcName .. ': ' .. reply,
        '',
        'Answer as {"evidence": the exact words from ' .. npcName .. '\'s reply where they end the conversation, or '
            .. '"none"}.',
    }
    return M.promptText(template, system, lines)
end

M.LEAVE_SCHEMA_JSON = '{"type":"object","properties":{"evidence":{"type":"string","maxLength":160}},'
    .. '"required":["evidence"]}'

-- Exits written only as an action (the model rarely quotes stage directions), e.g. *walks away without a word*
local exitActions = {
    'walks? away', 'walks? off', 'storms? off', 'stalks? off', 'stomps? off', 'leaves', 'turns? %a+ back',
    'turns? away', 'slams? the door',
}

function M.actionExit(reply)
    for action in reply:lower():gmatch('%*([^*]+)%*') do
        for _, pattern in ipairs(exitActions) do
            if action:find(pattern) then
                return true
            end
        end
    end
    return false
end

return M
