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

local actions = require('scripts.llm.actions')
local budget = require('scripts.llm.budget')
local cards = require('scripts.llm.cards')
local followers = require('scripts.llm.followers')
local generated = require('scripts.llm.generated')
local handover = require('scripts.llm.handover')
local json = require('scripts.llm.json')
local knowledge = require('scripts.llm.knowledge')
local lorebook = require('scripts.llm.lorebook')
local persuasion = require('scripts.llm.persuasion')
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
local ACTION_TIMEOUT = 60
local MAX_SAVED_EVENTS = 5

-- npc id -> { greeting = string, turns = list of { role, text }, events = list of strings, lastUsed = game time }
local histories = {}
-- The NPC whose dialogue window is open, or nil
local dialogueNpc = nil
-- The turn in progress: { id, stage = 'reply'|'action'|'transfer', npc, npcName, userText, limits }, or nil.
-- The text input stays disabled until the whole turn (reply, then an optional item exchange) is finished.
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
    return not recalled and earlierTurns > 0
end

local function setInput(enabled, hint)
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

-- A turn runs through these stages, with the text input disabled until it is finished:
--   'intent'         what does the player do in their line: give an item, persuade (admire, intimidate, taunt),
--                    or ask the NPC to follow, wait or leave? Persuasion and followers are resolved here
--   'confirmOffer'   if so, the player confirms with a dialogue choice ("Give X" / "Keep it")
--   'pretransfer'    the handover is applied first (with vanilla quest effects and rewards)...
--   'reply'          ...so the NPC's reply can react to it
--   'action'         if the exchange mentions items: did the NPC hand something over, or the player after all?
--   'confirmAction'  the player confirms ("Give X" / "Keep it", or "Accept X" / "Refuse")
--   'transfer'       applying that
-- Nothing changes hands without the player's click, so a wrong guess by the model costs nothing.
local function isWaitingForServer(stage)
    return stage == 'intent' or stage == 'reply' or stage == 'action' or stage == 'leave'
end

local function cancelPending()
    if pending then
        if isWaitingForServer(pending.stage) then
            llm.cancel(pending.id)
        end
        if pending.stage == 'confirmOffer' or pending.stage == 'confirmAction' or pending.stage == 'confirmFollow' then
            llm.setDialogueChoices({})
        end
        pending = nil
    end
end

-- Ends the turn in progress and gives the text input back to the player
local function finishTurn()
    pending = nil
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

local function applyTransfer(turn, transfer, stage)
    local effects = nil
    if transfer.transfer == 'player_to_npc' then
        local ok, found = pcall(handover.find, turn.npc, self.object, transfer.item, localsByNpc[turn.npc.id],
            transfer.count)
        effects = ok and found or nil
        if not ok then
            print('LLM handover lookup: ' .. tostring(found))
        end
    end
    turn.stage = stage
    turn.transfer = transfer
    turn.effects = effects
    core.sendGlobalEvent('LLMApplyTransfer', {
        player = self.object,
        npc = turn.npc,
        transfer = transfer.transfer,
        item = transfer.item,
        count = transfer.count,
        effects = effects,
    })
end

local function itemLabel(name, count)
    return count > 1 and (count .. ' ' .. name) or name
end

local numberWords = { 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'twenty', 'thirty',
    'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety', 'hundred', 'thousand' }

-- Whether the player named an amount themselves ("20 gold", "fifty drakes")
local function namesAmount(text)
    local lower = text:lower()
    if lower:find('%d') then
        return true
    end
    for _, word in ipairs(numberWords) do
        if lower:find('%f[%a]' .. word .. '%f[%A]') then
            return true
        end
    end
    return false
end

-- When the player gives an NPC something a vanilla quest line asks for, use the quest's amount (e.g. Vodunius
-- Nuccius's 100 drakes) instead of the model's guess, as long as the player has that many and didn't name an
-- amount of their own.
local function useQuestAmount(turn, transfer, candidates)
    if transfer.transfer ~= 'player_to_npc' or namesAmount(turn.userText) then
        return
    end
    local ok, required = pcall(handover.requiredCount, turn.npc, self.object, transfer.item, localsByNpc[turn.npc.id])
    if not ok or not required then
        return
    end
    for _, c in ipairs(candidates) do
        if c.id == transfer.item and c.playerCount >= required then
            transfer.count = required
            return
        end
    end
end

local function gmstValues()
    local values = {}
    for key, default in pairs(persuasion.DEFAULT_GMST) do
        local ok, value = pcall(core.getGMST, key)
        values[key] = (ok and type(value) == 'number') and value or default
    end
    return values
end

local function persuasionStats(actor)
    local fatigue = types.Actor.stats.dynamic.fatigue(actor)
    return {
        speechcraft = types.NPC.stats.skills.speechcraft(actor).modified,
        personality = types.Actor.stats.attributes.personality(actor).modified,
        luck = types.Actor.stats.attributes.luck(actor).modified,
        reputation = types.NPC.stats.reputation(actor).current,
        level = types.Actor.stats.level(actor).current,
        fatigueCurrent = fatigue.current,
        fatigueMax = fatigue.base,
    }
end

local function conversationFor(npc)
    if not conversation or conversation.npc ~= npc then
        conversation = { npc = npc, attempts = {}, permanent = 0 }
    end
    return conversation
end

-- Plain-words outcome lines for the model; no numbers
local persuasionOutcomes = {
    admire = {
        [true] = "The stranger's words flattered %s, and it worked: %s warms to the stranger.",
        [false] = "The stranger tried to flatter %s, but it fell flat: %s is unimpressed.",
    },
    intimidate = {
        [true] = "The stranger's threat worked: %s is afraid of the stranger and will do as told, but resents it.",
        [false] = "The stranger tried to intimidate %s, but it failed: %s is not scared, only annoyed.",
    },
    taunt = {
        [true] = "The stranger's insult struck home: %s is angry and hurt.",
        [false] = "%s shrugs off the stranger's insult, but thinks less of the stranger.",
    },
}

-- Vanilla persuasion for an admire/intimidate/taunt line; returns a line for the [What just happened] note
local function persuade(turn, kind)
    local npc = turn.npc
    local convo = conversationFor(npc)
    convo.attempts[kind] = (convo.attempts[kind] or 0) + 1
    if convo.attempts[kind] > persuasion.MAX_ATTEMPTS_PER_KIND then
        return string.format('The stranger keeps repeating the same approach; %s is tired of it and it has no effect.',
            turn.npcName)
    end
    local disposition = types.NPC.getDisposition(npc, self.object)
    local gmst = gmstValues()
    local result = persuasion.attempt(kind, persuasionStats(self.object), persuasionStats(npc), disposition,
        math.random(0, 99), gmst)
    if not convo.originalBase then
        convo.originalBase = types.NPC.getBaseDisposition(npc, self.object)
    end
    convo.permanent = convo.permanent + result.perm
    if result.temp ~= 0 then
        core.sendGlobalEvent('LLMModDisposition', { npc = npc, player = self.object, delta = result.temp })
    end
    if kind == persuasion.TYPES.intimidate and result.success then
        convo.coerced = true
    end
    if kind == persuasion.TYPES.taunt or (kind == persuasion.TYPES.intimidate and not result.success) then
        convo.upset = true
    end
    if result.fight ~= 0 or result.flee ~= 0 then
        core.sendGlobalEvent('LLMModAI', { npc = npc, fight = result.fight, flee = result.flee })
    end
    local useTypes = I.SkillProgression.SKILL_USE_TYPES
    I.SkillProgression.skillUsed('speechcraft',
        { useType = result.success and useTypes.Speechcraft_Success or useTypes.Speechcraft_Fail })
    local line = string.format(persuasionOutcomes[kind][result.success], turn.npcName, turn.npcName)

    -- How close is the NPC to violence? The engine's own rule, with this attempt's changes included
    local dispositionAfter = math.min(disposition + result.temp, disposition + result.perm)
    local dx, dy = npc.position.x - self.position.x, npc.position.y - self.position.y
    local fight = types.Actor.stats.ai.fight(npc).modified + result.fight
    local term = persuasion.fightTerm(fight, math.sqrt(dx * dx + dy * dy), dispositionAfter, gmst)
    if term >= persuasion.ATTACK_THRESHOLD then
        turn.endReason = 'attack'
        line = line .. string.format(' %s loses their temper and attacks the stranger.', turn.npcName)
    elseif term >= persuasion.THREATENING_THRESHOLD then
        line = line .. string.format(' %s is barely holding back from violence and threatens the stranger.', turn.npcName)
    elseif dispositionAfter <= 20 then
        turn.endReason = 'fedUp'
        line = line .. string.format(' %s has had enough of the stranger and ends the conversation.', turn.npcName)
    end
    print(string.format('LLM persuasion: %s %s -> %s, temporary %+d, permanent %+d, fight %+d, fight term %d', kind,
        npc.recordId, result.success and 'success' or 'failure', result.temp, result.perm, result.fight, term))
    return line
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

local followReasons = {
    afraid = '%s agrees to follow the stranger, but only out of fear, and resents it.',
    rank = '%s agrees to follow, because the stranger outranks them.',
    likes = '%s agrees to come along: they like the stranger.',
    quest = "%s can't come along: they have their own business to attend to right now.",
    essential = "%s can't come along: they have their own business to attend to right now.",
    job = '%s likes the stranger, but refuses: they have work to do here and cannot leave their post.',
    dislikes = "%s refuses to follow: they don't like or trust the stranger enough.",
}

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

-- Shows "Give X" / "Keep it" (or "Accept X" / "Refuse") as dialogue choices and waits for the click
local function askToConfirm(turn, transfer, stage)
    turn.stage = stage
    turn.proposed = transfer
    local item = itemLabel(transfer.name or transfer.item, transfer.count)
    local choices
    if transfer.transfer == 'player_to_npc' then
        choices = { { id = 'yes', label = l10n('giveChoice', { item = item }) }, { id = 'no', label = l10n('keepChoice') } }
    else
        choices = { { id = 'yes', label = l10n('acceptChoice', { item = item }) }, { id = 'no', label = l10n('refuseChoice') } }
    end
    llm.setDialogueChoices(choices)
    setInput(false, l10n('chooseHint'))
end

local startReply

-- The player clicked one of the confirmation choices
local function onChoice(choiceId)
    local turn = pending
    if turn and turn.stage == 'ended' and choiceId == 'goodbye' then
        I.UI.removeMode('Dialogue')
        return
    end
    if not turn or (turn.stage ~= 'confirmOffer' and turn.stage ~= 'confirmAction' and turn.stage ~= 'confirmFollow') then
        return
    end
    if turn.stage == 'confirmFollow' then
        -- The NPC already agreed in their reply; the player now decides whether to take them along
        local decision = turn.followDecision
        turn.followDecision = nil
        if choiceId == 'yes' then
            core.sendGlobalEvent('LLMFollow', { npc = turn.npc, player = self.object, reason = decision.reason })
            setFollowerState(turn.npc, 'following', decision.reason)
            ui.showMessage(l10n('followNotice', { name = turn.npcName }), { showInDialogue = true })
            table.insert(historyFor(turn.npc).events, string.format('%s started following the stranger.', turn.npcName))
        else
            table.insert(historyFor(turn.npc).events,
                string.format('%s offered to come along, but the stranger decided against it.', turn.npcName))
        end
        finishTurn()
        return
    end
    local transfer = turn.proposed
    turn.proposed = nil
    if turn.stage == 'confirmOffer' then
        if choiceId == 'yes' then
            applyTransfer(turn, transfer, 'pretransfer')
        else
            startReply(turn)
        end
    else
        if choiceId == 'yes' then
            applyTransfer(turn, transfer, 'transfer')
        else
            finishTurn()
        end
    end
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
    local id = llm.request(actions.encodeRequest(json, body, schemaText), async:callback(guarded(stage .. ' check', callback)),
        { endpoint = 'completion', timeout = ACTION_TIMEOUT })
    if not id then
        return false
    end
    turn.id = id
    turn.stage = stage
    return true
end

local function onActionReply(id, candidates, reply, response)
    if not pending or pending.id ~= id or pending.stage ~= 'action' then
        return
    end
    local transfer = actions.parse(decodeAnswer(response, 'action check'), candidates, actions.NPC_GIVES, reply)
    if transfer then
        useQuestAmount(pending, transfer, candidates)
        askToConfirm(pending, transfer, 'confirmAction')
    else
        finishTurn()
    end
end

-- After a reply: if an item could have changed hands, ask the model to classify the exchange.
-- @return true if a check was started (the turn continues), false if the turn is over
local function startActionCheck(turn, reply)
    -- Only what the NPC carries: the player giving was already decided before the reply
    local candidates = actions.findCandidates({ turn.userText, reply }, {}, inventoryItems(turn.npc),
        turn.limits.actionCandidates)
    if #candidates == 0 then
        return false
    end
    local userName = playerName()
    local exchange = {
        { speaker = userName, text = turn.userText },
        { speaker = turn.npcName, text = reply },
    }
    local body = {
        prompt = actions.prompt(template(), turn.npcName, userName, exchange, candidates),
        n_predict = 128,
        temperature = 0,
        stop = template().stop,
    }
    local id
    local started = sendClassification(turn, body, actions.schemaJson(candidates), 'action', function(response)
        onActionReply(id, candidates, reply, response)
    end)
    id = turn.id
    return started
end

local function addHappened(turn, line)
    turn.happened = turn.happened or {}
    table.insert(turn.happened, line)
end

-- Handles what the player did in their line, before the NPC replies
local function onIntentReply(id, candidates, response)
    if not pending or pending.id ~= id or pending.stage ~= 'intent' then
        return
    end
    local turn = pending
    local result = actions.parseIntent(decodeAnswer(response, 'intent check'), candidates, turn.userText)
    local intent = result and result.intent or 'none'

    if intent == 'give' then
        useQuestAmount(turn, result.transfer, candidates)
        askToConfirm(turn, result.transfer, 'confirmOffer')
        return
    elseif intent == 'admire' or intent == 'intimidate' or intent == 'taunt' then
        local ok, line = pcall(persuade, turn, intent)
        if ok then
            addHappened(turn, line)
        else
            print('LLM persuasion: ' .. tostring(line))
        end
    elseif intent == 'follow' then
        if followerState(turn.npc) == 'following' then
            addHappened(turn, string.format('%s is already following the stranger.', turn.npcName))
        else
            local convo = conversationFor(turn.npc)
            local ok, decision = pcall(followers.decideFor, turn.npc, self.object, convo.coerced)
            if not ok then
                print('LLM follow decision: ' .. tostring(decision))
            elseif decision.agrees then
                -- The reply comes first, so the player hears the NPC agree; the choice follows it
                turn.followDecision = decision
                addHappened(turn, string.format(followReasons[decision.reason], turn.npcName))
            else
                addHappened(turn, string.format(followReasons[decision.reason], turn.npcName))
            end
        end
    elseif intent == 'wait' then
        if followerState(turn.npc) == 'following' then
            core.sendGlobalEvent('LLMWait', { npc = turn.npc, player = self.object })
            setFollowerState(turn.npc, 'waiting')
            ui.showMessage(l10n('waitNotice', { name = turn.npcName }), { showInDialogue = true })
            addHappened(turn, string.format('%s stops and will wait here for the stranger.', turn.npcName))
        else
            addHappened(turn, string.format("%s isn't travelling with the stranger.", turn.npcName))
        end
    elseif intent == 'dismiss' then
        local state = followerState(turn.npc)
        if state == 'following' or state == 'waiting' then
            core.sendGlobalEvent('LLMDismiss', { npc = turn.npc, player = self.object })
            setFollowerState(turn.npc, nil)
            ui.showMessage(l10n('dismissNotice', { name = turn.npcName }), { showInDialogue = true })
            addHappened(turn, string.format('%s stops travelling with the stranger and will head home.', turn.npcName))
            table.insert(historyFor(turn.npc).events, string.format('%s stopped following the stranger.', turn.npcName))
        end
    end
    startReply(turn)
end

-- Before the reply: what does the player do in this line (give, persuade, follow, ...)?
-- @return true if the check was started
local function startIntentCheck(turn)
    local candidates = actions.findCandidates({ turn.userText }, inventoryItems(self.object), {},
        turn.limits.actionCandidates)
    local history = historyFor(turn.npc)
    local npcLastLine = history.greeting
    for i = #history.turns, 1, -1 do
        if history.turns[i].role == 'model' then
            npcLastLine = history.turns[i].text
            break
        end
    end
    local body = {
        prompt = actions.intentPrompt(template(), turn.npcName, playerName(), turn.userText, candidates, npcLastLine),
        n_predict = 128,
        temperature = 0,
        stop = template().stop,
    }
    local id
    local started = sendClassification(turn, body, actions.intentSchemaJson(candidates), 'intent', function(response)
        onIntentReply(id, candidates, response)
    end)
    id = turn.id
    return started
end

local function onTransferApplied(result)
    if not pending or (pending.stage ~= 'transfer' and pending.stage ~= 'pretransfer') then
        return
    end
    local turn = pending
    if result.ok then
        local item = itemLabel(result.name, result.count)
        local notice = result.transfer == 'player_to_npc' and 'itemRemoved' or 'itemAdded'
        ui.showMessage(l10n(notice, { item = item }), { showInDialogue = true })
        -- No journal notice here: the engine shows "Your journal has been updated" itself when an entry is added
        local rewards = {}
        for _, reward in ipairs(result.applied and result.applied.rewards or {}) do
            local label = itemLabel(reward.name, reward.count)
            rewards[#rewards + 1] = label
            ui.showMessage(l10n('itemAdded', { item = label }), { showInDialogue = true })
        end
        local event
        if result.transfer == 'player_to_npc' then
            event = string.format('The stranger gave %s %s.', turn.npcName, item)
        else
            event = string.format('%s gave the stranger %s.', turn.npcName, item)
        end
        if turn.effects and turn.effects.note then
            event = turn.effects.note
        end
        if #rewards > 0 then
            event = event .. string.format(' %s rewarded the stranger with %s.', turn.npcName, table.concat(rewards, ', '))
        end
        table.insert(historyFor(turn.npc).events, event)
        if turn.stage == 'pretransfer' then
            turn.justHappened = { item = item, effects = turn.effects, rewards = rewards }
        end
    else
        print('LLM transfer failed: ' .. tostring(result.error))
    end
    if turn.stage == 'pretransfer' then
        startReply(turn)
    else
        finishTurn()
    end
end

local CHAT_BLOCK_HOURS = 24
local ATTACK_BLOCK_HOURS = 72

-- The NPC ends the AI conversation: notice, a single Goodbye choice, and they refuse to talk for a while
local function endChat(turn, reason)
    chatEnded = true
    turn.stage = 'ended'
    ui.showMessage(l10n('endsConversation', { name = turn.npcName }), { showInDialogue = true })
    llm.setDialogueInput({ visible = false })
    llm.setDialogueChoices({ { id = 'goodbye', label = l10n('goodbyeChoice') } })
    local hours = reason == 'attack' and ATTACK_BLOCK_HOURS or CHAT_BLOCK_HOURS
    blocked[turn.npc.id] = core.getGameTime() + hours * 3600
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
    if answer and actions.evidenceFound(answer.evidence, reply) then
        endChat(turn, 'leaves')
        return
    end
    local ok, started = pcall(startActionCheck, turn, reply)
    if not (ok and started) then
        finishTurn()
    end
end

-- While the NPC is upset: does their reply end the conversation?
local function startLeaveCheck(turn, reply)
    local body = {
        prompt = actions.leavePrompt(template(), turn.npcName, playerName(), reply),
        n_predict = 96,
        temperature = 0,
        stop = template().stop,
    }
    local id
    local started = sendClassification(turn, body, actions.LEAVE_SCHEMA_JSON, 'leave', function(response)
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

    local continues = false
    if not response.ok then
        local errorText = response.error or ('HTTP ' .. tostring(response.status))
        ui.showMessage(l10n('serverError', { error = errorText }), { showInDialogue = true })
    else
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
            continues = true
        elseif isUpset(turn) and actions.actionExit(reply) then
            endChat(turn, 'leaves')
            continues = true
        elseif isUpset(turn) and not turn.followDecision and not turn.justHappened then
            local okCheck, started = pcall(startLeaveCheck, turn, reply)
            continues = okCheck and started
            if not okCheck then
                print('LLM leave check: ' .. tostring(started))
            end
        elseif turn.followDecision then
            -- The NPC agreed to come along in this reply: now the player confirms
            turn.stage = 'confirmFollow'
            llm.setDialogueChoices({
                { id = 'yes', label = l10n('followChoice', { name = turn.npcName }) },
                { id = 'no', label = l10n('neverMindChoice') },
            })
            setInput(false, l10n('chooseHint'))
            continues = true
        -- A handover before the reply already settled this turn's exchange
        elseif not turn.justHappened then
            local okCheck, started = pcall(startActionCheck, turn, reply)
            continues = okCheck and started
            if not okCheck then
                print('LLM action check: ' .. tostring(started))
            end
        end
    end

    if not continues then
        finishTurn()
    end
end

-- Tells the model about a handover that just happened, with vanilla's reaction and rewards, so the reply
-- plays it out instead of a generic thank-you
local function justHappenedNote(turn)
    local happened = turn.justHappened
    if not happened then
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
    local lines = { '[What just happened]', string.format('The stranger has just handed %s %s.', turn.npcName, happened.item) }
    if happened.effects and happened.effects.text then
        lines[#lines + 1] = string.format('In the original story, %s reacts like this: "%s"', turn.npcName,
            sanitize.toDrawable(expandVanillaText(happened.effects.text, turn.npc)))
    end
    if #happened.rewards > 0 then
        lines[#lines + 1] = string.format('%s has given the stranger a reward: %s.', turn.npcName,
            table.concat(happened.rewards, ', '))
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
    -- Things that happened in this conversation, such as items changing hands (this turn's handover is
    -- described separately below)
    local eventCount = #history.events - (turn.justHappened and 1 or 0)
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
    turn.stage = 'reply'
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
        limits = budget.fromContextSize(advancedSettings:get('contextSize'), generalSettings:get('replyTokens')),
    }
    pending = turn

    -- Show the player's line like a topic heading, then wait for the reply
    llm.addDialogueResponse('', { title = userText })
    setInput(false, l10n('thinking', { name = npcName }))

    local ok, started = pcall(startIntentCheck, turn)
    if not ok then
        print('LLM intent check: ' .. tostring(started))
    end
    if not (ok and started) then
        startReply(turn)
    end
end

local function onUiModeChanged(data)
    if data.newMode == 'Dialogue' then
        local freshWindow = data.oldMode == nil
        if data.arg and types.NPC.objectIsInstance(data.arg) then
            if dialogueNpc ~= data.arg then
                cancelPending()
                endConversation()
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
        local events = {}
        local allEvents = history.events or {}
        for j = math.max(1, #allEvents - MAX_SAVED_EVENTS + 1), #allEvents do
            events[#events + 1] = allEvents[j]
        end
        saved[ids[i]] = {
            greeting = history.greeting,
            turns = turns,
            events = events,
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
        LLMTransferApplied = guarded('transfer result', onTransferApplied),
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
