-- Derives every size limit used by the prompt builder from a single context size, so raising the
-- server's context later only means changing one setting. The limits at 8K are deliberately tight
-- for small (around 12B) models; larger contexts grow them up to fixed maximums.

local M = {}

local CHARS_PER_TOKEN = 3.5
local UNITS_PER_METER = 70 -- Morrowind units are about 1.4 cm

-- Rough token estimate; good enough for budgeting without a tokenizer.
function M.estimateTokens(text)
    return math.ceil(#text / CHARS_PER_TOKEN)
end

-- Cuts `text` to roughly `tokens` tokens, preferring to end at a sentence or line break.
function M.truncate(text, tokens)
    local maxChars = math.floor(tokens * CHARS_PER_TOKEN)
    if #text <= maxChars then
        return text
    end
    local cut = text:sub(1, maxChars)
    local lastBreak = cut:match('.*()[%.!?\n]')
    if lastBreak and lastBreak > maxChars / 4 then
        cut = cut:sub(1, lastBreak)
    end
    return cut
end

-- @param contextSize number of tokens the server was started with (llama-server -c)
-- @param replyTokens maximum reply length in tokens
-- @param overrides optional table replacing any derived value by name
function M.fromContextSize(contextSize, replyTokens, overrides)
    contextSize = math.max(2048, contextSize or 8192)
    replyTokens = replyTokens or 170
    -- 0 at 8K, 1 at 16K, 2 at 32K and above
    local level = math.max(0, math.min(2, math.log(contextSize / 8192) / math.log(2)))

    local limits = {
        contextSize = contextSize,
        replyTokens = replyTokens,
        cardTokens = math.floor(math.min(1200 + 600 * level, contextSize * 0.25)),
        sceneTokens = math.floor(250 + 100 * level),
        knowledgeTokens = math.floor(300 + 150 * level),
        maxTopics = math.floor(3 + level),
        maxPeople = math.floor(4 + 2 * level),
        maxDoors = math.floor(4 + level),
        maxThings = math.floor(6 + 2 * level),
        sceneRadius = 25 * UNITS_PER_METER,
        -- Room for template tokens and estimation error
        safetyTokens = 256,
    }
    for key, value in pairs(overrides or {}) do
        limits[key] = value
    end
    return limits
end

M.UNITS_PER_METER = UNITS_PER_METER

return M
