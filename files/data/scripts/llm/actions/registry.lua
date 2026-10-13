-- The actions a conversation can take. Each action module (give, persuade, follow, service) declares entries for two
-- checks:
--   intents    what the player does in their line, decided before the NPC replies
--   proposals  what the NPC offers in their reply, decided afterwards; the player confirms with a dialogue choice
-- An entry is { name, describe(ctx), params, available(ctx), parse(ctx, answer), run(game, turn, params) }:
--   describe   one line for the check's prompt
--   params     answer fields the entry uses, from PARAMS below (e.g. item and count)
--   available  whether to offer the entry in this check; offering fewer makes the classifier more accurate
--   parse      turns a valid answer into the entry's params, or nil to ignore it (optional)
--   run        applies it in game (scripts/llm/player.lua passes `game`, its API for actions); returns 'paused' if
--              it took over the turn (it waits for a choice before the reply)
--   noneWords  words that name the intent but often appear in lines that don't mean it (optional)
-- This module builds a check's prompt and schema from the entries that are available, and parses its answer.
-- `ctx` is plain data: { npcName, playerName, userLine, npcLastLine, reply, candidates, services, followerState,
-- serviceUsed }.

local check = require('scripts.llm.actions.check')

local M = {}

M.modules = {
    require('scripts.llm.actions.give'),
    require('scripts.llm.actions.persuade'),
    require('scripts.llm.actions.follow'),
    require('scripts.llm.actions.service'),
}

M.INTENT = 'intent'
M.PROPOSAL = 'proposal'

-- Answer fields an entry can use, in the order they appear in the schema
local PARAM_ORDER = { 'item', 'count', 'service' }

local PARAMS = {
    item = {
        context = function(ctx, kind)
            local giver = kind == M.INTENT and ctx.playerName or ctx.npcName
            local countField = kind == M.INTENT and 'playerCount' or 'npcCount'
            local what = kind == M.INTENT and 'could be given' or 'could be involved'
            local lines = { 'Items ' .. giver .. ' carries that ' .. what .. ' (id - name - count):' }
            for _, c in ipairs(ctx.candidates) do
                lines[#lines + 1] = string.format('%s - %s - %d', c.id, c.name or c.id, c[countField])
            end
            if #ctx.candidates == 0 then
                lines[#lines + 1] = '(none)'
            end
            return lines
        end,
        answer = function(ctx, users)
            return '"item": item id or "none" (only for ' .. users .. ')'
        end,
        schema = function(ctx)
            local ids = { check.jsonString('none') }
            for _, c in ipairs(ctx.candidates) do
                ids[#ids + 1] = check.jsonString(c.id)
            end
            return '{"enum":[' .. table.concat(ids, ',') .. ']}'
        end,
    },
    count = {
        answer = function(ctx, users)
            return '"count": number (only for ' .. users .. '; use the amount named in the conversation, for example '
                .. 'a price ' .. ctx.npcName .. ' asked for)'
        end,
        schema = function(ctx)
            return string.format('{"type":"integer","minimum":0,"maximum":%d}', check.maxCount(ctx.candidates))
        end,
    },
    service = {
        context = function(ctx)
            local names = {}
            for _, id in ipairs(ctx.services) do
                names[#names + 1] = id
            end
            return { 'Services ' .. ctx.npcName .. ' offers: ' .. table.concat(names, ', ') }
        end,
        answer = function(ctx, users)
            return '"service": one of those services or "none" (only for ' .. users .. ')'
        end,
        schema = function(ctx)
            local ids = { check.jsonString('none') }
            for _, id in ipairs(ctx.services) do
                ids[#ids + 1] = check.jsonString(id)
            end
            return '{"enum":[' .. table.concat(ids, ',') .. ']}'
        end,
    },
}

-- The entries of one kind available in this context, in module order
function M.entries(kind, ctx)
    local list = {}
    for _, module in ipairs(M.modules) do
        for _, entry in ipairs((kind == M.INTENT and module.intents or module.proposals) or {}) do
            local ok, available = pcall(entry.available or function()
                return true
            end, ctx)
            if ok and available then
                list[#list + 1] = entry
            elseif not ok then
                print('LLM action ' .. entry.name .. ': ' .. tostring(available))
            end
        end
    end
    return list
end

local function field(kind)
    return kind == M.INTENT and 'intent' or 'action'
end

-- Which params the entries use, in schema order, each with the names of the entries that use it
local function usedParams(entries)
    local users = {}
    for _, entry in ipairs(entries) do
        for _, param in ipairs(entry.params or {}) do
            users[param] = users[param] or {}
            table.insert(users[param], entry.name)
        end
    end
    local list = {}
    for _, param in ipairs(PARAM_ORDER) do
        if users[param] then
            list[#list + 1] = { name = param, users = table.concat(users[param], ' or ') }
        end
    end
    return list
end

-- The check's prompt, or nil if no entry is available
function M.prompt(kind, template, ctx, entries)
    if #entries == 0 then
        return nil
    end
    local system
    if kind == M.INTENT then
        system = 'You are the game master of a Morrowind role-play. Classify what ' .. ctx.playerName .. ' does to '
            .. ctx.npcName .. ' in their latest line. Intents:\n'
    else
        system = 'You are the game master of a Morrowind role-play. Decide what ' .. ctx.npcName .. ' does in their '
            .. 'latest reply to ' .. ctx.playerName .. '. Actions:\n'
    end
    -- Words an intent is detected by, which also often appear in lines that don't mean it
    local noneWords = {}
    for _, entry in ipairs(entries) do
        system = system .. '- ' .. entry.name .. ': ' .. entry.describe(ctx) .. '\n'
        for _, word in ipairs(entry.noneWords or {}) do
            noneWords[#noneWords + 1] = '"' .. word .. '"'
        end
    end
    if kind == M.INTENT then
        local words = ''
        if #noneWords > 0 then
            words = ', and words like ' .. table.concat(noneWords, ', ', 1, #noneWords - 1)
                .. (#noneWords > 1 and ' or ' or '') .. noneWords[#noneWords] .. ' used another way'
        end
        system = system .. '- none: anything else, including questions, offers with a condition' .. words .. '.\n'
    else
        system = system .. '- none: anything else.\n'
    end
    system = system .. 'Answer with JSON only.'

    local lines = {}
    if kind == M.INTENT then
        if ctx.npcLastLine and ctx.npcLastLine ~= '' then
            lines[#lines + 1] = ctx.npcName .. ' (just before): ' .. ctx.npcLastLine
        end
        lines[#lines + 1] = ctx.playerName .. ': ' .. ctx.userLine
    else
        lines[#lines + 1] = 'Conversation:'
        lines[#lines + 1] = ctx.playerName .. ': ' .. ctx.userLine
        lines[#lines + 1] = ctx.npcName .. ': ' .. ctx.reply
    end
    local params = usedParams(entries)
    for _, param in ipairs(params) do
        if PARAMS[param.name].context then
            lines[#lines + 1] = ''
            for _, line in ipairs(PARAMS[param.name].context(ctx, kind)) do
                lines[#lines + 1] = line
            end
        end
    end
    lines[#lines + 1] = ''
    local judged = kind == M.INTENT and (ctx.playerName .. '\'s latest line') or (ctx.npcName .. '\'s latest reply')
    local answer = { '"evidence": the exact words from ' .. judged .. ' that show the ' .. field(kind) .. ', or "none"',
        '"' .. field(kind) .. '": one of the ' .. field(kind) .. 's' }
    for _, param in ipairs(params) do
        answer[#answer + 1] = PARAMS[param.name].answer(ctx, param.users)
    end
    lines[#lines + 1] = 'Answer as {' .. table.concat(answer, ', ') .. '}.'
    return check.promptText(template, system, lines)
end

-- The check's JSON schema with a fixed property order: evidence first, then the intent or action, then the params
function M.schemaJson(kind, ctx, entries)
    local names = { check.jsonString('none') }
    for _, entry in ipairs(entries) do
        names[#names + 1] = check.jsonString(entry.name)
    end
    local properties = {
        string.format('"evidence":{"type":"string","maxLength":%d}', check.MAX_EVIDENCE_LENGTH),
        '"' .. field(kind) .. '":{"enum":[' .. table.concat(names, ',') .. ']}',
    }
    local required = { '"evidence"', '"' .. field(kind) .. '"' }
    for _, param in ipairs(usedParams(entries)) do
        properties[#properties + 1] = '"' .. param.name .. '":' .. PARAMS[param.name].schema(ctx)
        required[#required + 1] = '"' .. param.name .. '"'
    end
    return '{"type":"object","properties":{' .. table.concat(properties, ',') .. '},"required":['
        .. table.concat(required, ',') .. ']}'
end

-- Turns a check's answer into { entry, params }, or nil when nothing happens. The answer counts only if its
-- evidence really appears in the judged line (the player's line for intents, the NPC's reply for proposals).
function M.parse(kind, answer, ctx, entries)
    if type(answer) ~= 'table' then
        return nil
    end
    local name = answer[field(kind)]
    if type(name) ~= 'string' or name == 'none' then
        return nil
    end
    local judged = kind == M.INTENT and ctx.userLine or ctx.reply
    if not check.evidenceFound(answer.evidence, judged or '') then
        return nil
    end
    for _, entry in ipairs(entries) do
        if entry.name == name then
            local params = {}
            if entry.parse then
                params = entry.parse(ctx, answer)
                if not params then
                    return nil
                end
            end
            return { entry = entry, params = params }
        end
    end
    return nil
end

return M
