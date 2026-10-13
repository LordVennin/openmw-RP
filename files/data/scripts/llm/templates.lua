-- Instruct templates in the SillyTavern style: the prompt is built here and sent to the server's raw text completion
-- endpoint, instead of relying on the chat template embedded in the model file.
-- Supporting another model family means adding an entry to `templates`.

local templates = {
    gemma4 = {
        systemPrefix = '<|turn>system\n',
        systemSuffix = '<turn|>\n',
        userPrefix = '<|turn>user\n',
        userSuffix = '<turn|>\n',
        modelPrefix = '<|turn>model\n',
        modelSuffix = '<turn|>\n',
        -- Gemma 4 always sees a thought block before an answer; with thinking off it is empty. Leaving it out
        -- puts the reply off-distribution and causes misspellings and nonsense words.
        replyPrefix = '<|channel>thought\n<channel|>',
        -- '<|channel>' starts a thinking block, which would continue past the reply
        stop = { '<turn|>', '<|turn>', '<|channel>' },
        -- Special tokens that must never reach the dialogue window if the model leaks them.
        specialTokens = { '<turn|>', '<|turn>', '<|channel>', '<channel|>', '<|think|>', '<bos>', '<eos>' },
    },
    -- Pygmalion's Metharme format, recommended for many Mistral Nemo role-play fine-tunes (e.g. Rocinante).
    -- Turns have no closing token; the next turn's prefix ends the previous one.
    metharme = {
        systemPrefix = '<|system|>',
        systemSuffix = '',
        userPrefix = '<|user|>',
        userSuffix = '',
        modelPrefix = '<|model|>',
        modelSuffix = '',
        stop = { '<|user|>', '<|model|>', '<|system|>', '</s>' },
        specialTokens = { '<|user|>', '<|model|>', '<|system|>', '</s>', '<s>' },
    },
    -- Mistral v3 "Tekken" (Mistral Nemo), without whitespace and without [SYSTEM_PROMPT]: the system text goes
    -- first as plain text, player lines are wrapped in [INST]...[/INST] and model replies end with </s>.
    mistralTekken = {
        systemPrefix = '',
        systemSuffix = '',
        userPrefix = '[INST]',
        userSuffix = '[/INST]',
        modelPrefix = '',
        modelSuffix = '</s>',
        stop = { '</s>', '[INST]', '[/INST]' },
        specialTokens = { '</s>', '<s>', '[INST]', '[/INST]', '[SYSTEM_PROMPT]', '[/SYSTEM_PROMPT]' },
    },
}

-- Sampler values that work well with the roleplay fine-tune (taken from a working SillyTavern setup).
local samplers = {
    temperature = 0.85,
    dynatemp_range = 0.15,
    top_k = 80,
    top_p = 0.95,
    min_p = 0.01,
    repeat_penalty = 1.05,
    repeat_last_n = 550,
}

-- Model file name patterns (lower case) and the template their family was trained on, checked in order.
-- Mistral Nemo role-play fine-tunes such as Rocinante mostly use Metharme.
local byModelName = {
    { 'gemma', 'gemma4' },
    { 'tekken', 'mistralTekken' },
    { 'rocinante', 'metharme' },
    { 'metharme', 'metharme' },
    { 'pygmalion', 'metharme' },
    { 'nemo', 'metharme' },
}

-- The template for a model file name, or nil if it's not recognised
local function forModel(fileName)
    local lower = (fileName or ''):lower()
    for _, entry in ipairs(byModelName) do
        if lower:find(entry[1], 1, true) then
            return entry[2]
        end
    end
    return nil
end

return {
    templates = templates,
    samplers = samplers,
    default = 'gemma4',
    forModel = forModel,
}
