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
        -- '<|channel>' starts a thinking block, which would continue past the reply
        stop = { '<turn|>', '<|turn>', '<|channel>' },
        -- Special tokens that must never reach the dialogue window if the model leaks them.
        specialTokens = { '<turn|>', '<|turn>', '<|channel>', '<channel|>', '<|think|>', '<bos>', '<eos>' },
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

return {
    templates = templates,
    samplers = samplers,
    default = 'gemma4',
}
