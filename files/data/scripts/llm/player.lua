-- AI dialogue: lets the player talk to any NPC in their own words from the vanilla dialogue window.
-- The engine shows a text input in the dialogue window and sends typed lines as the DialogueTextInput event;
-- replies come from a local LLM server through openmw.llm and are added to the dialogue history.

local async = require('openmw.async')
local core = require('openmw.core')
local llm = require('openmw.llm')
local self = require('openmw.self')
local storage = require('openmw.storage')
local types = require('openmw.types')
local ui = require('openmw.ui')

local budget = require('scripts.llm.budget')
local cards = require('scripts.llm.cards')
local generated = require('scripts.llm.generated')
local json = require('scripts.llm.json')
local knowledge = require('scripts.llm.knowledge')
local prompt = require('scripts.llm.prompt')
local sanitize = require('scripts.llm.sanitize')
local scene = require('scripts.llm.scene')
local templates = require('scripts.llm.templates')

local l10n = core.l10n('LLMDialogue')
local generalSettings = storage.playerSection('SettingsLLMDialogue')
local advancedSettings = storage.playerSection('SettingsLLMDialogueAdvanced')

local SAVE_VERSION = 1
local MAX_SAVED_NPCS = 30
local MAX_SAVED_TURNS = 20
local REQUEST_TIMEOUT = 120

-- npc id -> { greeting = string, turns = list of { role, text }, lastUsed = game time }
local histories = {}
-- The NPC whose dialogue window is open, or nil
local dialogueNpc = nil
-- The request waiting for a reply: { id, npc, npcName, userText }, or nil
local pending = nil
-- Whether the earlier conversation was already replayed into the open dialogue window
local recalled = false
-- Number of history turns that existed when the dialogue window opened (the "earlier conversation")
local earlierTurns = 0
local lastPrompt = nil

local function isEnabled()
    return generalSettings:get('enabled') ~= false
end

local function template()
    return templates.templates[advancedSettings:get('template') or templates.default]
        or templates.templates[templates.default]
end

local function playerName()
    return types.NPC.record(self).name
end

local function historyFor(npc)
    local history = histories[npc.id]
    if not history then
        history = { turns = {} }
        histories[npc.id] = history
    end
    history.lastUsed = core.getGameTime()
    return history
end

-- Expands vanilla dialogue macros (%PCName, %Name, ...) and strips hyperlink markers.
local function expandVanillaText(text, npc)
    local npcRecord = types.NPC.record(npc)
    local playerRecord = types.NPC.record(self)
    local function raceName(id)
        local race = types.NPC.races.record(id)
        return race and race.name or ''
    end
    local function className(id)
        local class = types.NPC.classes.record(id)
        return class and class.name or ''
    end
    local values = {
        pcname = playerRecord.name,
        pcrace = raceName(playerRecord.race),
        pcclass = className(playerRecord.class),
        name = npcRecord.name,
        race = raceName(npcRecord.race),
        class = className(npcRecord.class),
        cell = npc.cell and npc.cell.name or '',
    }
    text = text:gsub('%%(%a+)', function(macro)
        return values[macro:lower()] or ''
    end)
    return (text:gsub('[@#]', ''))
end

local function responseInfo(e)
    local record = core.dialogue[e.type].records[e.recordId]
    if not record then
        return nil
    end
    for _, info in pairs(record.infos) do
        if info.id == e.infoId then
            return record, info
        end
    end
    return nil
end

local function canRecall()
    return not recalled and earlierTurns > 0
end

local function setInput(enabled, hint)
    llm.setDialogueInput({
        visible = isEnabled(),
        enabled = enabled,
        hint = hint or '',
        recallLabel = canRecall() and l10n('recall') or '',
    })
end

-- Replays the saved conversation with the NPC into the dialogue window, styled like live chat
local function recallConversation(npc)
    local history = histories[npc.id]
    if recalled or not history or earlierTurns == 0 then
        return
    end
    recalled = true
    llm.addDialogueResponse('', { title = l10n('earlierConversation') })
    for i = 1, math.min(earlierTurns, #history.turns) do
        local turn = history.turns[i]
        if turn.role == 'user' then
            llm.addDialogueResponse('', { title = turn.topic or turn.text })
        else
            llm.addDialogueResponse(turn.text)
        end
    end
    llm.addDialogueResponse('', { title = l10n('nowHeading') })
    setInput(pending == nil, pending and l10n('thinking', { name = pending.npcName }) or nil)
end

local function cancelPending()
    if pending then
        llm.cancel(pending.id)
        pending = nil
    end
end

local function onReply(request, response)
    if not pending or pending.id ~= request.id then
        return
    end
    pending = nil

    if not response.ok then
        local errorText = response.error or ('HTTP ' .. tostring(response.status))
        ui.showMessage(l10n('serverError', { error = errorText }), { showInDialogue = true })
    else
        local ok, data = pcall(json.decode, response.body)
        local content = ok and type(data) == 'table' and data.content or ''
        local reply = sanitize.reply(content, {
            specialTokens = template().specialTokens,
            speakerName = request.npcName,
        })
        if ok and data.stop_type == 'limit' then
            reply = sanitize.trimIncomplete(reply)
        end
        if reply == '' then
            reply = '*' .. request.npcName .. ' says nothing.*'
        end
        local history = historyFor(request.npc)
        table.insert(history.turns, { role = 'user', text = request.userText })
        table.insert(history.turns, { role = 'model', text = reply })
        llm.addDialogueResponse(reply)
    end

    if dialogueNpc then
        setInput(true)
    end
end

local function sendLine(npc, rawText)
    local userText = sanitize.toDrawable(rawText):gsub('^%s+', ''):gsub('%s+$', '')
    if userText == '' then
        return
    end
    local npcName = types.NPC.record(npc).name
    local userName = playerName()

    local limits = budget.fromContextSize(advancedSettings:get('contextSize'), generalSettings:get('replyTokens'))
    local history = historyFor(npc)

    local card = cards.load(npc.recordId)
    if card then
        card = cards.substitute(card, npcName, userName)
    else
        card = generated.build(npc, history.greeting)
    end
    card.firstMes = history.greeting or card.firstMes
    card = generated.fit(card, limits.cardTokens)

    local notes = {}
    local sceneNote = scene.build(npc, self.object, advancedSettings:get('sceneDetail') or 'full', limits)
    if sceneNote then
        notes[#notes + 1] = sceneNote
    end
    -- Vanilla topic answers for topics mentioned in the player's line or the NPC's last line
    local lastNpcLine = history.greeting or ''
    for i = #history.turns, 1, -1 do
        if history.turns[i].role == 'model' then
            lastNpcLine = history.turns[i].text
            break
        end
    end
    local ok, knowledgeNote = pcall(knowledge.build, npc, self.object, { userText, lastNpcLine }, function(text)
        return sanitize.toDrawable(expandVanillaText(text, npc))
    end, limits)
    if ok and knowledgeNote then
        notes[#notes + 1] = knowledgeNote
    elseif not ok then
        print('LLM knowledge: ' .. tostring(knowledgeNote))
    end

    local text, stop = prompt.build({
        template = template(),
        card = card,
        npcName = npcName,
        playerName = userName,
        scene = #notes > 0 and table.concat(notes, '\n\n') or nil,
        scenePosition = advancedSettings:get('scenePosition') or 'system',
        history = history.turns,
        userText = userText,
        limits = limits,
    })
    lastPrompt = text

    local body = { prompt = text, n_predict = limits.replyTokens, stop = stop }
    for key, value in pairs(templates.samplers) do
        body[key] = value
    end
    body.temperature = generalSettings:get('temperature') or body.temperature

    local request = { npc = npc, npcName = npcName, userText = userText }
    local id, err = llm.request(json.encode(body), async:callback(function(response)
        onReply(request, response)
    end), { endpoint = 'completion', timeout = REQUEST_TIMEOUT })
    if not id then
        ui.showMessage(l10n('serverError', { error = err }), { showInDialogue = true })
        return
    end
    request.id = id
    pending = request

    -- Show the player's line like a topic heading, then wait for the reply
    llm.addDialogueResponse('', { title = userText })
    setInput(false, l10n('thinking', { name = npcName }))
end

local function onUiModeChanged(data)
    if data.newMode == 'Dialogue' then
        local freshWindow = data.oldMode == nil
        if data.arg and types.NPC.objectIsInstance(data.arg) then
            if dialogueNpc ~= data.arg then
                cancelPending()
                freshWindow = true
            end
            dialogueNpc = data.arg
        end
        if freshWindow and dialogueNpc then
            -- A fresh dialogue window starts with an empty history; everything saved so far can be recalled
            recalled = false
            local history = histories[dialogueNpc.id]
            earlierTurns = history and #history.turns or 0
        end
        if dialogueNpc then
            if pending then
                setInput(false, l10n('thinking', { name = pending.npcName }))
            else
                setInput(true)
            end
        else
            llm.setDialogueInput({ visible = false })
        end
    elseif data.newMode == nil then
        -- The dialogue window (and every window on top of it) has closed
        cancelPending()
        dialogueNpc = nil
    end
end

local function onDialogueResponse(e)
    if not isEnabled() or not types.NPC.objectIsInstance(e.actor) or e.actor.type == types.Player then
        return
    end
    local ok, record, info = pcall(responseInfo, e)
    if not ok or not info or not info.text or info.text == '' then
        return
    end
    local text = sanitize.toDrawable(expandVanillaText(info.text, e.actor))
    local history = historyFor(e.actor)
    if e.type == 'greeting' then
        history.greeting = text
    elseif e.type == 'topic' then
        -- Vanilla topic answers become context, as if the player had asked about the topic
        table.insert(history.turns, { role = 'user', text = 'Tell me about ' .. record.name .. '.', topic = record.name })
        table.insert(history.turns, { role = 'model', text = text })
    end
end

local function onSave()
    local ids = {}
    for id in pairs(histories) do
        ids[#ids + 1] = id
    end
    table.sort(ids, function(a, b)
        return (histories[a].lastUsed or 0) > (histories[b].lastUsed or 0)
    end)
    local saved = {}
    for i = 1, math.min(#ids, MAX_SAVED_NPCS) do
        local history = histories[ids[i]]
        local turns = {}
        local first = math.max(1, #history.turns - MAX_SAVED_TURNS + 1)
        -- Keep pairs together: start on a player turn
        if history.turns[first] and history.turns[first].role ~= 'user' then
            first = first + 1
        end
        for j = first, #history.turns do
            local turn = history.turns[j]
            turns[#turns + 1] = { role = turn.role, text = turn.text, topic = turn.topic }
        end
        saved[ids[i]] = { greeting = history.greeting, turns = turns, lastUsed = history.lastUsed }
    end
    return { version = SAVE_VERSION, histories = saved }
end

local function onLoad(data)
    histories = {}
    if data and data.version == SAVE_VERSION and data.histories then
        histories = data.histories
    end
end

return {
    interfaceName = 'LLMDialogue',
    interface = {
        version = 1,
        -- The last prompt sent to the model, for debugging: print(I.LLMDialogue.lastPrompt())
        lastPrompt = function()
            return lastPrompt
        end,
        -- Forgets the conversation with an NPC
        clearHistory = function(npc)
            histories[npc.id] = nil
        end,
    },
    engineHandlers = {
        onSave = onSave,
        onLoad = onLoad,
    },
    eventHandlers = {
        UiModeChanged = onUiModeChanged,
        DialogueResponse = onDialogueResponse,
        DialogueAction = function(e)
            if isEnabled() and e.action == 'recall' and types.NPC.objectIsInstance(e.actor) then
                recallConversation(e.actor)
            end
        end,
        DialogueTextInput = function(e)
            if isEnabled() and not pending and types.NPC.objectIsInstance(e.actor) then
                sendLine(e.actor, e.text)
            end
        end,
    },
}
