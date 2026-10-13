local I = require('openmw.interfaces')

I.Settings.registerPage({
    key = 'LLMDialogue',
    l10n = 'LLMDialogue',
    name = 'pageName',
    description = 'pageDescription',
})

I.Settings.registerGroup({
    key = 'SettingsLLMDialogue',
    page = 'LLMDialogue',
    l10n = 'LLMDialogue',
    name = 'generalGroup',
    permanentStorage = true,
    order = 0,
    settings = {
        {
            key = 'enabled',
            renderer = 'checkbox',
            name = 'enabled',
            description = 'enabledDescription',
            default = true,
        },
        {
            key = 'replyTokens',
            renderer = 'number',
            name = 'replyTokens',
            description = 'replyTokensDescription',
            default = 170,
            argument = { integer = true, min = 16, max = 1024 },
        },
        {
            key = 'temperature',
            renderer = 'number',
            name = 'temperature',
            description = 'temperatureDescription',
            default = 0.85,
            argument = { min = 0, max = 2 },
        },
        {
            key = 'refusalDuration',
            renderer = 'select',
            name = 'refusalDuration',
            description = 'refusalDurationDescription',
            default = 'normal',
            argument = { l10n = 'LLMDialogue', items = { 'off', 'short', 'normal' } },
        },
    },
})

I.Settings.registerGroup({
    key = 'SettingsLLMDialogueAdvanced',
    page = 'LLMDialogue',
    l10n = 'LLMDialogue',
    name = 'advancedGroup',
    permanentStorage = true,
    order = 1,
    settings = {
        {
            key = 'template',
            renderer = 'select',
            name = 'template',
            description = 'templateDescription',
            default = 'auto',
            argument = { l10n = 'LLMDialogue', items = { 'auto', 'gemma4', 'metharme', 'mistralTekken' } },
        },
        {
            key = 'sceneDetail',
            renderer = 'select',
            name = 'sceneDetail',
            description = 'sceneDetailDescription',
            default = 'full',
            argument = { l10n = 'LLMDialogue', items = { 'off', 'brief', 'full' } },
        },
        {
            key = 'scenePosition',
            renderer = 'select',
            name = 'scenePosition',
            description = 'scenePositionDescription',
            default = 'system',
            argument = { l10n = 'LLMDialogue', items = { 'system', 'beforeLastMessage' } },
        },
    },
})
