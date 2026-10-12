-- Assembles a text completion prompt from an instruct template, in this order:
--   system (system prompt, character card, setting primer, scene note)
--   -> greeting as a model turn -> alternating history -> the player's line -> open model turn with "Name:".
-- No OpenMW APIs are used here, so this module can be tested outside the game.

local budget = require('scripts.llm.budget')

local M = {}

M.defaultSystemPrompt = 'You are {{char}}, a person living on Vvardenfell. Stay in character at all times and '
    .. 'reply only as {{char}}, never as the stranger. Develop the conversation naturally and keep replies short: '
    .. 'a few sentences of speech. Put actions and descriptions in asterisks, like *nods slowly*.'

M.primer = 'Setting: Vvardenfell, an island in the province of Morrowind, in the year 3E 427. The Empire rules, '
    .. 'but the Great Houses, the Tribunal Temple and the Ashlanders hold their own power.\n'
    .. 'Speak like a person of this world. Never mention game mechanics, numbers or being an AI. '
    .. 'Do not use emojis.'

local function section(label, text)
    if text and text ~= '' then
        return label and (label .. ': ' .. text) or text
    end
    return nil
end

-- SillyTavern macros in text that did not come from a card (cards are substituted by cards.lua)
local function substitute(text, npcName, playerName)
    return (text:gsub('{{char}}', (npcName:gsub('%%', '%%%%'))):gsub('{{user}}', (playerName:gsub('%%', '%%%%'))))
end

-- SillyTavern separates example chats with <START>; show them as plain blocks instead
local function formatExamples(text)
    if not text then
        return nil
    end
    text = text:gsub('<START>%s*', '\n'):gsub('^%s+', ''):gsub('%s+$', '')
    return text ~= '' and text or nil
end

local function systemText(card, scene, scenePosition, npcName, playerName)
    local parts = {}
    local function add(text)
        if text then
            parts[#parts + 1] = text
        end
    end
    add(card.systemPrompt or substitute(M.defaultSystemPrompt, npcName, playerName))
    add(section(nil, card.description))
    add(section('Personality', card.personality))
    add(section('Scenario', card.scenario))
    add(section('Example dialogue', formatExamples(card.mesExample)))
    add(M.primer)
    if scenePosition ~= 'beforeLastMessage' then
        add(scene)
    end
    return table.concat(parts, '\n\n')
end

local function modelTurn(template, name, text)
    return template.modelPrefix .. name .. ': ' .. text .. template.modelSuffix
end

local function userTurn(template, text)
    return template.userPrefix .. text .. template.userSuffix
end

-- @param args table:
--   template      instruct template from templates.lua
--   card          normalized card (cards.lua / generated.lua), macros already substituted
--   npcName       name of the NPC
--   playerName    name of the player
--   scene         scene note or nil (scene.lua), may include the knowledge note (knowledge.lua)
--   scenePosition 'system' (default) or 'beforeLastMessage'
--   history       list of { role = 'user'|'model', text = string }, oldest first
--   userText      the player's new line
--   limits        table from budget.fromContextSize
-- @return prompt string, list of stop strings, number of history entries kept
function M.build(args)
    local template = args.template
    local card = args.card
    local limits = args.limits

    local head = template.systemPrefix .. systemText(card, args.scene, args.scenePosition, args.npcName, args.playerName) .. template.systemSuffix
    if card.firstMes then
        head = head .. modelTurn(template, args.npcName, card.firstMes)
    end

    local tail = ''
    if args.scene and args.scenePosition == 'beforeLastMessage' then
        tail = template.systemPrefix .. args.scene .. template.systemSuffix
    end
    local userLine = args.userText
    if card.postHistoryInstructions then
        userLine = userLine .. '\n\n' .. card.postHistoryInstructions
    end
    tail = tail .. userTurn(template, userLine) .. template.modelPrefix .. (template.replyPrefix or '') .. args.npcName .. ':'

    local turns = {}
    for i, entry in ipairs(args.history or {}) do
        if entry.role == 'user' then
            turns[i] = userTurn(template, entry.text)
        else
            turns[i] = modelTurn(template, args.npcName, entry.text)
        end
    end

    -- Drop the oldest turns until everything fits next to the reply
    local available = limits.contextSize - limits.replyTokens - limits.safetyTokens
        - budget.estimateTokens(head) - budget.estimateTokens(tail)
    local first = 1
    local used = 0
    for i = #turns, 1, -1 do
        local cost = budget.estimateTokens(turns[i])
        if used + cost > available then
            first = i + 1
            break
        end
        used = used + cost
    end
    -- Start the kept history on a player turn so roles keep alternating after the greeting
    while turns[first] and args.history[first].role ~= 'user' do
        first = first + 1
    end

    local prompt = head .. table.concat(turns, '', first) .. tail

    local stop = {}
    for _, s in ipairs(template.stop) do
        stop[#stop + 1] = s
    end
    stop[#stop + 1] = '\n' .. args.playerName .. ':'
    -- The model starting a second reply of its own
    stop[#stop + 1] = '\n' .. args.npcName .. ':'

    return prompt, stop, #turns - first + 1
end

return M
