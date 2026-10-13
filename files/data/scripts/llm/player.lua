-- AI dialogue: lets the player talk to any NPC in their own words from the vanilla dialogue window.
-- The engine shows a text input in the dialogue window and sends typed lines as the DialogueTextInput event;
-- replies come from a local LLM server through openmw.llm and are added to the dialogue history.

local async = require('openmw.async')
local core = require('openmw.core')
local I = require('openmw.interfaces')
local llm = require('openmw.llm')
local self = require('openmw.self')
local storage = require('openmw.storage')
local types = require('openmw.types')
local ui = require('openmw.ui')

local budget = require('scripts.llm.budget')
local cards = require('scripts.llm.cards')
local check = require('scripts.llm.actions.check')
local generated = require('scripts.llm.generated')
local json = require('scripts.llm.json')
local knowledge = require('scripts.llm.knowledge')
local lorebook = require('scripts.llm.lorebook')
local memory = require('scripts.llm.memory')
local prompt = require('scripts.llm.prompt')
local registry = require('scripts.llm.actions.registry')
local sanitize = require('scripts.llm.sanitize')
local scene = require('scripts.llm.scene')
local service = require('scripts.llm.actions.service')
local templates = require('scripts.llm.templates')

local l10n = core.l10n('LLMDialogue')
local generalSettings = storage.playerSection('SettingsLLMDialogue')
local advancedSettings = storage.playerSection('SettingsLLMDialogueAdvanced')

local SAVE_VERSION = 1
local MAX_SAVED_NPCS = 30
local MAX_SAVED_TURNS = 20
local REQUEST_TIMEOUT = 120
local ACTION_TIMEOUT = 60
local MAX_SAVED_EVENTS = 5

-- npc id -> { greeting = string, turns = list of { role, text }, events = list of strings, lastUsed = game time }
local histories = {}
-- The NPC whose dialogue window is open, or nil
local dialogueNpc = nil
-- The turn in progress, or nil: { id, stage (see below), npc, npcName, userText, limits, eventsBefore, happened,
-- afterChoices, choiceHandler, onApplied, endReason, settled, serviceUsed }.
-- The text input stays disabled until the whole turn (checks, reply, choices) is finished.
local pending = nil
-- npc id -> the NPC's mwscript variables (lower-case names), as last reported by the global script
local localsByNpc = {}
-- Whether the earlier conversation was already replayed into the open dialogue window
local recalled = false
-- Number of history turns that existed when the dialogue window opened (the "earlier conversation")
local earlierTurns = 0
local lastPrompt = nil
-- Persuasion during the open conversation: { npc, originalBase, permanent, attempts = { kind = n }, coerced }.
-- Like vanilla, changes are temporary while talking and only the permanent part remains when the window closes.
local conversation = nil
-- Followers as last reported by the global script: npc id -> { npc, state, reason }
local followerStates = {}
-- NPCs who refuse to talk to the player until a game time: npc id -> game time (seconds)
local blocked = {}
-- Whether the NPC ended the AI conversation in the open dialogue window
local chatEnded = false
-- Memory summaries: NPCs with a summary request in flight, and results waiting for their window to close
local summarizing = {}
local deferredSummaries = {}

local function isEnabled()
    return generalSettings:get('enabled') ~= false
end

-- Why the AI server can't take requests yet, as a hint for the text box, or nil if it can
local serverHints = { starting = 'serverLoading', noModel = 'serverNoModel', failed = 'serverFailed' }
local function serverHint()
    local key = serverHints[llm.serverStatus().state]
    return key and l10n(key)
end
-- Whether the text box is waiting for the server, so onFrame enables it once the server is ready
local waitingForServer = false

local function template()
    local name = advancedSettings:get('template') or 'auto'
    if name == 'auto' then
        name = templates.forModel(llm.serverStatus().model) or templates.default
    end
    return templates.templates[name] or templates.templates[templates.default]
end

local function playerName()
    return types.NPC.record(self).name
end

local function historyFor(npc)
    local history = histories[npc.id]
    if not history then
        history = { turns = {}, events = {} }
        histories[npc.id] = history
    end
    history.events = history.events or {}
    history.lastUsed = core.getGameTime()
    return history
end

-- Everything an actor carries, grouped by record id: list of { id, name, count }
local function inventoryItems(actor)
    local items, byId = {}, {}
    for _, item in ipairs(types.Actor.inventory(actor):getAll()) do
        local entry = byId[item.recordId]
        if not entry then
            local ok, record = pcall(item.type.record, item)
            entry = { id = item.recordId, name = ok and record and record.name or item.recordId, count = 0 }
            byId[item.recordId] = entry
            items[#items + 1] = entry
        end
        entry.count = entry.count + item.count
    end
    return items
end

local function requestLocals(npc)
    core.sendGlobalEvent('LLMGetLocals', { player = self.object, npc = npc })
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
    local history = dialogueNpc and histories[dialogueNpc.id]
    return not recalled and (earlierTurns > 0 or (history ~= nil and history.summary ~= nil))
end

local function setInput(enabled, hint)
    waitingForServer = false
    if enabled then
        local notReady = serverHint()
        if notReady then
            enabled, hint, waitingForServer = false, notReady, true
        end
    end
    llm.setDialogueInput({
        visible = isEnabled() and not chatEnded,
        enabled = enabled,
        hint = hint or '',
        recallLabel = canRecall() and l10n('recall') or '',
    })
end

-- Replays the saved conversation with the NPC into the dialogue window, styled like live chat
local function recallConversation(npc)
    local history = histories[npc.id]
    if recalled or not history or (earlierTurns == 0 and not history.summary) then
        return
    end
    recalled = true
    llm.addDialogueResponse('', { title = l10n('earlierConversation') })
    if history.summary then
        llm.addDialogueResponse(history.summary)
    end
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

-- A turn runs through these stages, with the text input disabled until it is finished:
--   'intent'         what does the player do in their line? One check, built from the available actions
--                    (scripts/llm/actions/registry.lua): give an item, persuade, ask to follow, ask for a service...
--   'confirmBefore'  an action that needs the player's click before the reply (giving an item: "Give X" / "Keep it")
--   'applying'       waiting for the global script to apply something (an item moving, with quest effects)
--   'reply'          the NPC's reply, told what just happened
--   'leave'          while the NPC is upset: does their reply end the conversation?
--   'proposal'       does the NPC offer something in their reply (an item, a service)?
--   'confirmAfter'   the player's choice after the reply ("Take X along", "Barter", "Accept X"...)
--   'ended'          the NPC ended the conversation: only Goodbye is left
-- Nothing changes without the player's click, so a wrong guess by the model costs nothing. While the turn waits for
-- the server or the global script, the dialogue window can't be closed, so the reply is never lost.
local SERVER_STAGES = { intent = true, reply = true, leave = true, proposal = true }
local BUSY_STAGES = { intent = true, reply = true, leave = true, proposal = true, applying = true }

local function isWaitingForServer(stage)
    return SERVER_STAGES[stage] == true
end

local function setStage(turn, stage)
    turn.stage = stage
    llm.setDialogueBusy(BUSY_STAGES[stage] == true)
end

local function cancelPending()
    if pending then
        if isWaitingForServer(pending.stage) then
            llm.cancel(pending.id)
        end
        if pending.stage == 'confirmBefore' or pending.stage == 'confirmAfter' then
            llm.setDialogueChoices({})
        end
        pending = nil
    end
    llm.setDialogueBusy(false)
end

-- Ends the turn in progress and gives the text input back to the player
local function finishTurn()
    pending = nil
    llm.setDialogueBusy(false)
    if dialogueNpc then
        setInput(true)
    end
end

-- The model's JSON answer from a classification request, or nil
local function decodeAnswer(response, label)
    if not response.ok then
        print('LLM ' .. label .. ' failed: ' .. tostring(response.error or response.status))
        return nil
    end
    local ok, data = pcall(json.decode, response.body)
    if ok and type(data) == 'table' and type(data.content) == 'string' then
        local okAnswer, answer = pcall(json.decode, data.content)
        if okAnswer then
            return answer
        end
    end
    return nil
end

local function conversationFor(npc)
    if not conversation or conversation.npc ~= npc then
        conversation = { npc = npc, attempts = {}, permanent = 0 }
    end
    return conversation
end

-- At the end of a conversation, like vanilla: only the permanent part of persuasion remains
local function endConversation()
    if conversation and conversation.originalBase then
        core.sendGlobalEvent('LLMSetBaseDisposition', {
            npc = conversation.npc,
            player = self.object,
            value = conversation.originalBase + conversation.permanent,
        })
    end
    conversation = nil
end

local function followerState(npc)
    local entry = followerStates[npc.id]
    return entry and entry.state or nil
end

local function setFollowerState(npc, state, reason)
    if state then
        followerStates[npc.id] = { npc = npc, state = state, reason = reason }
    else
        followerStates[npc.id] = nil
    end
end

local function showChoices(turn, stage, choices)
    setStage(turn, stage)
    llm.setDialogueChoices(choices)
    setInput(false, l10n('chooseHint'))
end

-- After the reply: shows the choices an action left for the player, or ends the turn
local function showAfterChoices(turn)
    local choices = turn.afterChoices
    if choices then
        turn.afterChoices = nil
        showChoices(turn, 'confirmAfter', choices)
    else
        finishTurn()
    end
end

local startReply

-- What actions can do in game (scripts/llm/actions/*.lua)
local game = {
    player = self.object,
    l10n = l10n,
    conversation = conversationFor,
    setFollowerState = setFollowerState,
    finishTurn = function()
        finishTurn()
    end,
}
-- A line for the [What just happened] note of this turn's reply
function game.happened(turn, line)
    turn.happened = turn.happened or {}
    table.insert(turn.happened, line)
end
-- Something the NPC remembers from now on ([Recent events])
function game.historyEvent(npc, text)
    table.insert(historyFor(npc).events, text)
end
function game.notice(key, args)
    ui.showMessage(l10n(key, args), { showInDialogue = true })
end
function game.sendGlobal(name, payload)
    core.sendGlobalEvent(name, payload)
end
function game.locals(npc)
    return localsByNpc[npc.id]
end
-- Vanilla dialogue text made ready for the prompt
function game.expand(text, npc)
    return sanitize.toDrawable(expandVanillaText(text, npc))
end
-- Opens a service window (Barter, Training...) over the dialogue, as vanilla's service topics do
function game.openWindow(mode, npc)
    I.UI.addMode(mode, { target = npc })
end
-- Offers the player dialogue choices: 'before' the reply (the turn waits for the click), or 'after' it.
-- handler(choiceId) must end the turn (game.finishTurn) or, before the reply, go on to it (game.continueTurn).
function game.choices(turn, when, choices, handler)
    turn.choiceHandler = handler
    if when == 'before' then
        showChoices(turn, 'confirmBefore', choices)
    else
        turn.afterChoices = choices
    end
end
-- After a 'before' choice: goes on to the NPC's reply
function game.continueTurn(turn)
    setInput(false, l10n('thinking', { name = turn.npcName }))
    startReply(turn)
end
-- Sends an event to the global script and waits for its result (the global script answers with
-- LLMTransferApplied), then calls done(result)
function game.globalRequest(turn, name, payload, done)
    setStage(turn, 'applying')
    turn.onApplied = done
    core.sendGlobalEvent(name, payload)
end

-- The player clicked one of the dialogue choices
local function onChoice(choiceId)
    local turn = pending
    if turn and turn.stage == 'ended' and choiceId == 'goodbye' then
        I.UI.removeMode('Dialogue')
        return
    end
    if not turn or (turn.stage ~= 'confirmBefore' and turn.stage ~= 'confirmAfter') or not turn.choiceHandler then
        return
    end
    local handler = turn.choiceHandler
    turn.choiceHandler = nil
    handler(choiceId)
end

-- Runs a handler; on a Lua error, logs it and ends the turn so the dialogue never stays locked
local function guarded(name, fn)
    return function(...)
        local args = { ... }
        local count = select('#', ...)
        local ok, err = xpcall(function()
            return fn(unpack(args, 1, count))
        end, tostring)
        if not ok then
            print('LLM ' .. name .. ' failed: ' .. tostring(err))
            llm.setDialogueChoices({})
            finishTurn()
        end
    end
end

local function sendClassification(turn, body, schemaText, stage, callback)
    local id = llm.request(check.encodeRequest(json, body, schemaText), async:callback(guarded(stage .. ' check', callback)),
        { endpoint = 'completion', timeout = ACTION_TIMEOUT })
    if not id then
        return false
    end
    turn.id = id
    setStage(turn, stage)
    return true
end

local function npcLastLine(history)
    for i = #history.turns, 1, -1 do
        if history.turns[i].role == 'model' then
            return history.turns[i].text
        end
    end
    return history.greeting
end

-- What the action checks know about the turn. Intents look at the player's line and the items they carry;
-- proposals at the NPC's reply and the items the NPC carries.
local function checkContext(turn, kind, reply)
    local ctx = {
        npcName = turn.npcName,
        playerName = playerName(),
        userLine = turn.userText,
        npcLastLine = npcLastLine(historyFor(turn.npc)),
        reply = reply,
        services = service.forNpc(turn.npc),
        followerState = followerState(turn.npc),
        serviceUsed = turn.serviceUsed,
    }
    if kind == registry.INTENT then
        ctx.candidates = check.findCandidates({ turn.userText }, inventoryItems(self.object), {},
            turn.limits.actionCandidates)
    else
        ctx.candidates = check.findCandidates({ turn.userText, reply }, {}, inventoryItems(turn.npc),
            turn.limits.actionCandidates)
    end
    return ctx
end

-- Runs an action check; onResult(turn, chosen) gets { entry, params } or nil
-- @return true if a check was started, false if no action is possible
local function startCheck(turn, kind, reply, onResult)
    local ctx = checkContext(turn, kind, reply)
    local entries = registry.entries(kind, ctx)
    if #entries == 0 then
        return false
    end
    local body = {
        prompt = registry.prompt(kind, template(), ctx, entries),
        n_predict = 128,
        temperature = 0,
        stop = template().stop,
    }
    local stage = kind == registry.INTENT and 'intent' or 'proposal'
    local id
    local started = sendClassification(turn, body, registry.schemaJson(kind, ctx, entries), stage, function(response)
        if not pending or pending.id ~= id or pending.stage ~= stage then
            return
        end
        local chosen = registry.parse(kind, decodeAnswer(response, stage .. ' check'), ctx, entries)
        if chosen then
            print('LLM ' .. stage .. ': ' .. chosen.entry.name)
        end
        onResult(pending, chosen)
    end)
    id = turn.id
    return started
end

-- Runs an action's effect; true if it took over the turn (it waits for a choice before the reply)
local function runAction(turn, chosen)
    local ok, result = pcall(chosen.entry.run, game, turn, chosen.params)
    if not ok then
        print('LLM action ' .. chosen.entry.name .. ': ' .. tostring(result))
        return false
    end
    return result == 'paused'
end

-- Before the reply: what does the player do in this line?
local function onIntent(turn, chosen)
    if chosen and runAction(turn, chosen) then
        return
    end
    startReply(turn)
end

-- After the reply: does the NPC offer something the player can take up?
local function onProposal(turn, chosen)
    if chosen then
        runAction(turn, chosen)
    end
    showAfterChoices(turn)
end

local function startProposalCheck(turn, reply)
    local ok, started = pcall(startCheck, turn, registry.PROPOSAL, reply, onProposal)
    if not ok then
        print('LLM proposal check: ' .. tostring(started))
    end
    if not (ok and started) then
        finishTurn()
    end
end

-- How long an NPC refuses to talk after ending the conversation, by the Refusal Duration setting
local REFUSAL_HOURS = {
    off = { chat = 0, attack = 0 },
    short = { chat = 4, attack = 12 },
    normal = { chat = 24, attack = 72 },
}

-- The NPC ends the AI conversation: notice, a single Goodbye choice, and they refuse to talk for a while
local function endChat(turn, reason)
    chatEnded = true
    setStage(turn, 'ended')
    ui.showMessage(l10n('endsConversation', { name = turn.npcName }), { showInDialogue = true })
    llm.setDialogueInput({ visible = false })
    llm.setDialogueChoices({ { id = 'goodbye', label = l10n('goodbyeChoice') } })
    local refusal = REFUSAL_HOURS[generalSettings:get('refusalDuration')] or REFUSAL_HOURS.normal
    local hours = reason == 'attack' and refusal.attack or refusal.chat
    if hours > 0 then
        blocked[turn.npc.id] = core.getGameTime() + hours * 3600
    end
    local event = reason == 'attack' and '%s lost their temper and attacked the stranger.'
        or '%s angrily ended a conversation with the stranger.'
    table.insert(historyFor(turn.npc).events, string.format(event, turn.npcName))
end

local function isUpset(turn)
    return (conversation and conversation.npc == turn.npc and conversation.upset)
        or types.NPC.getDisposition(turn.npc, self.object) < 40
end

local function onLeaveReply(id, reply, response)
    if not pending or pending.id ~= id or pending.stage ~= 'leave' then
        return
    end
    local turn = pending
    local answer = decodeAnswer(response, 'leave check')
    if answer and check.evidenceFound(answer.evidence, reply) then
        endChat(turn, 'leaves')
        return
    end
    startProposalCheck(turn, reply)
end

-- While the NPC is upset: does their reply end the conversation?
local function startLeaveCheck(turn, reply)
    local body = {
        prompt = check.leavePrompt(template(), turn.npcName, playerName(), reply),
        n_predict = 96,
        temperature = 0,
        stop = template().stop,
    }
    local id
    local started = sendClassification(turn, body, check.LEAVE_SCHEMA_JSON, 'leave', function(response)
        onLeaveReply(id, reply, response)
    end)
    id = turn.id
    return started
end

local function onReply(id, response)
    if not pending or pending.id ~= id or pending.stage ~= 'reply' then
        return
    end
    local turn = pending

    if not response.ok then
        local errorText = response.error or ('HTTP ' .. tostring(response.status))
        ui.showMessage(l10n('serverError', { error = errorText }), { showInDialogue = true })
        finishTurn()
        return
    end
    local ok, data = pcall(json.decode, response.body)
    local content = ok and type(data) == 'table' and data.content or ''
    local reply = sanitize.reply(content, {
        specialTokens = template().specialTokens,
        speakerName = turn.npcName,
    })
    if ok and data.stop_type == 'limit' then
        reply = sanitize.trimIncomplete(reply)
    end
    if reply == '' then
        reply = '*' .. turn.npcName .. ' says nothing.*'
    end
    local history = historyFor(turn.npc)
    table.insert(history.turns, { role = 'user', text = turn.userText })
    table.insert(history.turns, { role = 'model', text = reply })
    llm.addDialogueResponse(reply)

    if turn.endReason then
        -- Decided before the reply (about to attack, or fed up): the reply played it out
        endChat(turn, turn.endReason)
    elseif isUpset(turn) and check.actionExit(reply) then
        endChat(turn, 'leaves')
    elseif turn.afterChoices then
        -- An action decided before the reply (the NPC agreed to come along, to trade...): now the player chooses
        showAfterChoices(turn)
    elseif turn.settled then
        -- A handover before the reply already settled this turn's exchange
        finishTurn()
    elseif isUpset(turn) then
        local okCheck, started = pcall(startLeaveCheck, turn, reply)
        if not okCheck then
            print('LLM leave check: ' .. tostring(started))
        end
        if not (okCheck and started) then
            startProposalCheck(turn, reply)
        end
    else
        startProposalCheck(turn, reply)
    end
end

-- Tells the model what happened in this turn before the reply (a handover with vanilla's reaction and rewards,
-- persuasion, a follower decision...), so the reply plays it out
local function justHappenedNote(turn)
    if not turn.happened or #turn.happened == 0 then
        return nil
    end
    local lines = { '[What just happened]' }
    for _, line in ipairs(turn.happened) do
        lines[#lines + 1] = line
    end
    lines[#lines + 1] = string.format('%s now reacts to this, in character and in their own words.', turn.npcName)
    return table.concat(lines, '\n')
end

startReply = function(turn)
    local npc = turn.npc
    local npcName = turn.npcName
    local userText = turn.userText
    local userName = playerName()
    local limits = turn.limits
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
    if history.summary then
        notes[#notes + 1] = '[What ' .. npcName .. ' remembers]\n' .. budget.truncate(history.summary, limits.memoryTokens)
    end
    local sceneNote = scene.build(npc, self.object, advancedSettings:get('sceneDetail') or 'full', limits)
    if sceneNote then
        notes[#notes + 1] = sceneNote
    end
    -- Vanilla topic answers for topics mentioned in the player's line or the NPC's last line
    local lastNpcLine = npcLastLine(history) or ''
    local ok, knowledgeNote = pcall(knowledge.build, npc, self.object, { userText, lastNpcLine }, function(text)
        return sanitize.toDrawable(expandVanillaText(text, npc))
    end, limits, localsByNpc[npc.id])
    if ok and knowledgeNote then
        notes[#notes + 1] = knowledgeNote
    elseif not ok then
        print('LLM knowledge: ' .. tostring(knowledgeNote))
    end
    -- Lore for what is mentioned and for where the conversation happens
    local place = npc.cell and npc.cell.name or ''
    if npc.cell and npc.cell.region and core.regions.records[npc.cell.region] then
        place = place .. '\n' .. core.regions.records[npc.cell.region].name
    end
    local okLore, loreNote = pcall(lorebook.build, { userText, lastNpcLine, place }, limits)
    if okLore and loreNote then
        notes[#notes + 1] = loreNote
    elseif not okLore then
        print('LLM lorebook: ' .. tostring(loreNote))
    end
    -- Things that happened in earlier turns, such as items changing hands (this turn's are described separately
    -- below, in [What just happened])
    local eventCount = math.min(#history.events, turn.eventsBefore or #history.events)
    if eventCount > 0 then
        local events = {}
        for i = math.max(1, eventCount - limits.recentEvents + 1), eventCount do
            events[#events + 1] = '- ' .. history.events[i]
        end
        notes[#notes + 1] = '[Recent events]\n' .. table.concat(events, '\n')
    end
    -- Who travels with the stranger, so the NPC knows (and knows about themselves)
    local travelling = {}
    for _, entry in pairs(followerStates) do
        if entry.npc:isValid() then
            local name = types.NPC.record(entry.npc).name
            local where = entry.state == 'waiting' and ' (told to wait)' or ''
            travelling[#travelling + 1] = '- ' .. name .. where
        end
    end
    if #travelling > 0 then
        notes[#notes + 1] = '[Travelling with the stranger]\n' .. table.concat(travelling, '\n')
    end
    local happenedNote = justHappenedNote(turn)
    if happenedNote then
        notes[#notes + 1] = happenedNote
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

    local id
    local requestId, err = llm.request(json.encode(body), async:callback(guarded('reply', function(response)
        onReply(id, response)
    end)), { endpoint = 'completion', timeout = REQUEST_TIMEOUT })
    if not requestId then
        ui.showMessage(l10n('serverError', { error = err }), { showInDialogue = true })
        finishTurn()
        return
    end
    id = requestId
    turn.id = requestId
    setStage(turn, 'reply')
end

local function sendLine(npc, rawText)
    local userText = sanitize.toDrawable(rawText):gsub('^%s+', ''):gsub('%s+$', '')
    if userText == '' then
        return
    end
    local npcName = types.NPC.record(npc).name
    local turn = {
        npc = npc,
        npcName = npcName,
        userText = userText,
        limits = budget.fromContextSize(llm.serverStatus().contextSize, generalSettings:get('replyTokens')),
        eventsBefore = #historyFor(npc).events,
    }
    pending = turn

    -- Show the player's line like a topic heading, then wait for the reply
    llm.addDialogueResponse('', { title = userText })
    setInput(false, l10n('thinking', { name = npcName }))

    local ok, started = pcall(startCheck, turn, registry.INTENT, nil, onIntent)
    if not ok then
        print('LLM intent check: ' .. tostring(started))
    end
    if not (ok and started) then
        startReply(turn)
    end
end

local function applySummary(npc, pendingSummary)
    local history = histories[npc.id]
    if history and memory.apply(history, pendingSummary.count, pendingSummary.fingerprint, pendingSummary.text) then
        print(string.format('LLM memory: summarized %d turns for %s', pendingSummary.count, npc.recordId))
    end
end

-- When a long conversation ends, fold its older turns into the NPC's memory summary (in the background)
local function startSummary(npc)
    local history = histories[npc.id]
    if summarizing[npc.id] or not memory.needsSummary(history) then
        return
    end
    local count = memory.countToSummarize(history)
    if count <= 0 then
        return
    end
    local turns = {}
    for i = 1, count do
        turns[i] = history.turns[i]
    end
    local npcName = types.NPC.record(npc).name
    local fingerprint = memory.fingerprint(history, count)
    local body = {
        prompt = memory.prompt(template(), npcName, history.summary, turns),
        n_predict = 200,
        temperature = 0.3,
        stop = template().stop,
    }
    local id = llm.request(json.encode(body), async:callback(function(response)
        summarizing[npc.id] = nil
        local ok, err = pcall(function()
            if not response.ok then
                print('LLM memory: summary failed: ' .. tostring(response.error or response.status))
                return
            end
            local data = json.decode(response.body)
            local text = sanitize.reply(type(data) == 'table' and data.content or '',
                { specialTokens = template().specialTokens, speakerName = npcName })
            local result = { count = count, fingerprint = fingerprint, text = text }
            if dialogueNpc == npc then
                deferredSummaries[npc.id] = result -- apply when this conversation ends
            else
                applySummary(npc, result)
            end
        end)
        if not ok then
            print('LLM memory: ' .. tostring(err))
        end
    end), { endpoint = 'completion', timeout = REQUEST_TIMEOUT })
    if id then
        summarizing[npc.id] = true
    end
end

-- A conversation with `npc` has ended: apply a waiting summary, then summarize if the history is long
local function onConversationClosed(npc)
    if not npc then
        return
    end
    local waiting = deferredSummaries[npc.id]
    if waiting then
        deferredSummaries[npc.id] = nil
        applySummary(npc, waiting)
    end
    startSummary(npc)
end

local function onUiModeChanged(data)
    if data.newMode == 'Dialogue' then
        local freshWindow = data.oldMode == nil
        if data.arg and types.NPC.objectIsInstance(data.arg) then
            if dialogueNpc ~= data.arg then
                cancelPending()
                endConversation()
                onConversationClosed(dialogueNpc)
                freshWindow = true
            end
            dialogueNpc = data.arg
        end
        if freshWindow and dialogueNpc then
            chatEnded = false
            local refusedUntil = blocked[dialogueNpc.id]
            if refusedUntil and core.getGameTime() < refusedUntil then
                ui.showMessage(l10n('refusesToTalk', { name = types.NPC.record(dialogueNpc).name }))
                dialogueNpc = nil
                I.UI.removeMode('Dialogue')
                return
            end
            blocked[dialogueNpc.id] = nil
            -- A fresh dialogue window starts with an empty history; everything saved so far can be recalled
            recalled = false
            local history = histories[dialogueNpc.id]
            earlierTurns = history and #history.turns or 0
            requestLocals(dialogueNpc)
            core.sendGlobalEvent('LLMGetFollowers', { player = self.object })
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
        endConversation()
        local closed = dialogueNpc
        dialogueNpc = nil
        onConversationClosed(closed)
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
        local events = {}
        local allEvents = history.events or {}
        for j = math.max(1, #allEvents - MAX_SAVED_EVENTS + 1), #allEvents do
            events[#events + 1] = allEvents[j]
        end
        saved[ids[i]] = {
            greeting = history.greeting,
            turns = turns,
            events = events,
            summary = history.summary,
            lastUsed = history.lastUsed,
        }
    end
    local now = core.getGameTime()
    local stillBlocked = {}
    for id, untilTime in pairs(blocked) do
        if untilTime > now then
            stillBlocked[id] = untilTime
        end
    end
    return { version = SAVE_VERSION, histories = saved, blocked = stillBlocked }
end

local function onLoad(data)
    histories = {}
    if data and data.version == SAVE_VERSION and data.histories then
        histories = data.histories
    end
    blocked = (data and data.blocked) or {}
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
        -- Runs while the game is paused in dialogue: enables the text box once the server is ready
        onFrame = function()
            if waitingForServer and dialogueNpc and not pending and not serverHint() then
                setInput(true)
            end
        end,
    },
    eventHandlers = {
        UiModeChanged = onUiModeChanged,
        DialogueResponse = onDialogueResponse,
        DialogueAction = guarded('dialogue action', function(e)
            if not isEnabled() or not types.NPC.objectIsInstance(e.actor) then
                return
            end
            if e.action == 'recall' then
                recallConversation(e.actor)
            else
                local choiceId = e.action:match('^choice:(.*)$')
                if choiceId then
                    onChoice(choiceId)
                end
            end
        end),
        LLMTransferApplied = guarded('transfer result', function(result)
            if pending and pending.stage == 'applying' and pending.onApplied then
                local done = pending.onApplied
                pending.onApplied = nil
                done(result)
            end
        end),
        LLMFollowers = function(data)
            followerStates = {}
            for _, entry in ipairs(data.followers or {}) do
                if entry.state ~= 'goingHome' then
                    followerStates[entry.npc.id] = { npc = entry.npc, state = entry.state, reason = entry.reason }
                end
            end
        end,
        LLMLocals = function(data)
            if data.npc then
                localsByNpc[data.npc.id] = data.vars
            end
        end,
        DialogueTextInput = guarded('text input', function(e)
            if isEnabled() and not pending and types.NPC.objectIsInstance(e.actor) then
                sendLine(e.actor, e.text)
            end
        end),
    },
}
