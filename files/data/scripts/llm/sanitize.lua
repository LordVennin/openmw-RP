-- Cleans model replies before they reach the dialogue window. The game fonts only cover ASCII and Latin-1 /
-- Latin Extended-A; anything else (emoji, CJK, symbols) would be drawn as '_', so it is mapped or dropped.

local M = {}

-- Typographic characters mapped to ASCII equivalents
local replacements = {
    ['\226\128\152'] = "'", -- left single quote
    ['\226\128\153'] = "'", -- right single quote
    ['\226\128\156'] = '"', -- left double quote
    ['\226\128\157'] = '"', -- right double quote
    ['\226\128\147'] = '-', -- en dash
    ['\226\128\148'] = '-', -- em dash
    ['\226\128\166'] = '...', -- ellipsis
    ['\226\128\162'] = '-', -- bullet
    ['\194\160'] = ' ', -- non-breaking space
}

local function codepoint(char)
    local b1, b2, b3, b4 = char:byte(1, -1)
    if #char == 1 then
        return b1
    elseif #char == 2 then
        return (b1 - 192) * 64 + (b2 - 128)
    elseif #char == 3 then
        return (b1 - 224) * 4096 + (b2 - 128) * 64 + (b3 - 128)
    elseif #char == 4 then
        return (b1 - 240) * 262144 + (b2 - 128) * 4096 + (b3 - 128) * 64 + (b4 - 128)
    end
    return nil
end

local function isDrawable(cp)
    return cp == 10 or (cp >= 32 and cp <= 126) or (cp >= 161 and cp <= 382)
end

-- Keeps only characters the game fonts can draw.
function M.toDrawable(text)
    local out = {}
    for char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        local mapped = replacements[char]
        if mapped then
            out[#out + 1] = mapped
        else
            local cp = codepoint(char)
            if cp and isDrawable(cp) then
                out[#out + 1] = char
            elseif cp == 9 then
                out[#out + 1] = ' '
            end
        end
    end
    return table.concat(out)
end

local function escapePattern(s)
    return (s:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0'))
end

-- @param text raw reply from the model
-- @param options { specialTokens = list of strings, speakerName = string }
function M.reply(text, options)
    options = options or {}
    for _, token in ipairs(options.specialTokens or {}) do
        text = text:gsub(escapePattern(token), '')
    end
    text = M.toDrawable(text)
    text = text:gsub('\r', '')
    -- The prompt already ends with "Name:", so a repeated "Name:" at the start is an echo
    if options.speakerName and options.speakerName ~= '' then
        text = text:gsub('^%s*' .. escapePattern(options.speakerName) .. '%s*:%s*', '')
    end
    text = text:gsub('[ ]+\n', '\n'):gsub('\n\n\n+', '\n\n'):gsub('  +', ' ')
    text = text:gsub('^%s+', ''):gsub('%s+$', '')
    return text
end

-- Drops an unfinished last sentence, for replies cut off by the token limit.
function M.trimIncomplete(text)
    local lastEnd = text:match('.*()[%.!?%*"]')
    if lastEnd and lastEnd > 1 then
        return text:sub(1, lastEnd)
    end
    return text
end

return M
