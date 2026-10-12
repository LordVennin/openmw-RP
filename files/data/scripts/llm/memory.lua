-- Rolling memory: when a long conversation ends, its older exchanges are folded into a short summary of what the NPC
-- remembers, written by the model in the background. The summary is saved and shown to the model as
-- "[What <npc> remembers]", so long relationships fit in the context instead of the oldest turns being dropped.
-- Pure functions: callers send the request and decide when to apply the result.

local M = {}

M.SUMMARIZE_AFTER = 16 -- turns (8 exchanges)
M.KEEP_TURNS = 8 -- the most recent turns stay verbatim

function M.needsSummary(history)
    return history ~= nil and #history.turns > M.SUMMARIZE_AFTER
end

-- How many of the oldest turns to fold into the summary. The kept part starts on a player turn.
function M.countToSummarize(history)
    local count = #history.turns - M.KEEP_TURNS
    while history.turns[count + 1] and history.turns[count + 1].role ~= 'user' do
        count = count + 1
    end
    return math.max(0, math.min(count, #history.turns))
end

-- @param turns the turns to summarize, oldest first: { role = 'user'|'model', text }
-- @param previous the NPC's earlier summary, or nil
function M.prompt(template, npcName, previous, turns)
    local system = 'You keep the memory of ' .. npcName .. ', a person on Vvardenfell. Write what ' .. npcName
        .. ' remembers about the stranger and their dealings, from ' .. npcName .. '\'s point of view, in at most 5 '
        .. 'short sentences. Keep names, promises, debts, items and quests. Use only facts from the text below; do not '
        .. 'invent anything. Plain sentences, no lists, no emojis.'
    local lines = {}
    if previous and previous ~= '' then
        lines[#lines + 1] = 'What ' .. npcName .. ' already remembered:'
        lines[#lines + 1] = previous
        lines[#lines + 1] = ''
    end
    lines[#lines + 1] = 'The conversation since then:'
    for _, turn in ipairs(turns) do
        local speaker = turn.role == 'user' and 'Stranger' or npcName
        lines[#lines + 1] = speaker .. ': ' .. (turn.topic and ('(asks about ' .. turn.topic .. ')') or turn.text)
    end
    return template.systemPrefix .. system .. template.systemSuffix
        .. template.userPrefix .. table.concat(lines, '\n') .. template.userSuffix
        .. template.modelPrefix .. (template.replyPrefix or '')
end

-- A fingerprint of the turns being summarized, to check they are still the oldest turns when the result arrives
function M.fingerprint(history, count)
    local first, last = history.turns[1], history.turns[count]
    return string.format('%d|%s|%s', count, first and first.text or '', last and last.text or '')
end

-- Replaces the summarized turns with the summary, if the history still starts with them.
-- @return true if applied
function M.apply(history, count, fingerprint, summary)
    if count <= 0 or #history.turns < count or M.fingerprint(history, count) ~= fingerprint then
        return false
    end
    if not summary or not summary:find('%S') then
        return false
    end
    for _ = 1, count do
        table.remove(history.turns, 1)
    end
    history.summary = summary
    return true
end

return M
