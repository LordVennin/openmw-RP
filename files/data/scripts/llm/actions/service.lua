-- NPC services through conversation: asking to trade, train, travel, buy spells, make spells, enchant or repair
-- opens the vanilla window, as clicking the service in the topic list does. The engine handles prices, skill caps
-- and gold. A service is possible only if the NPC offers it and vanilla wouldn't refuse it:
--   offered  the NPC's servicesOffered (from their class for autocalc NPCs); travel needs travel destinations
--   refused  the "Service Refusal" dialogue, evaluated by the engine itself (openmw.llm.serviceRefusal, the same
--            check as clicking the service topic), so every vanilla gate applies: guild membership and rank,
--            expulsion, disposition, bounty, quest state...
--   service        (intent) the player asks for a service; the NPC agrees or refuses in their reply, then the player
--                  gets a choice that opens the window
--   offer_service  (proposal) the NPC offers a service in their reply; the player gets the same choice

local core = require('openmw.core')
local llm = require('openmw.llm')
local types = require('openmw.types')

local M = {}

-- id: the name the model uses; key: the servicesOffered key; mode: the UI mode; gmst: vanilla's label for it;
-- verb, asks: the service in words, as the NPC offers it and as the player asks for it;
-- choice: the service number for vanilla's refusal check (MWBase::DialogueManager::ServiceType)
M.SERVICES = {
    { id = 'barter', key = 'Barter', mode = 'Barter', gmst = 'sBarter', choice = 1, label = 'Barter',
      verb = 'trade with the stranger', asks = 'to see or buy their wares' },
    { id = 'repair', key = 'Repair', mode = 'MerchantRepair', gmst = 'sRepair', choice = 2, label = 'Repair',
      verb = "repair the stranger's equipment", asks = 'to have equipment repaired' },
    { id = 'spells', key = 'Spells', mode = 'SpellBuying', gmst = 'sSpells', choice = 3, label = 'Spells',
      verb = 'sell the stranger spells', asks = 'to buy spells' },
    { id = 'training', key = 'Training', mode = 'Training', gmst = 'sServiceTrainingTitle', choice = 4,
      label = 'Training', verb = 'train the stranger', asks = 'to be trained or taught a skill' },
    { id = 'travel', key = 'Travel', mode = 'Travel', gmst = 'sTravel', choice = 5, label = 'Travel',
      verb = 'take the stranger to another town', asks = 'for passage or a ride to another town' },
    { id = 'spellmaking', key = 'Spellmaking', mode = 'SpellCreation', gmst = 'sSpellmakingMenuTitle', choice = 6,
      label = 'Spellmaking', verb = 'make a spell for the stranger', asks = 'to create a spell of their own' },
    { id = 'enchanting', key = 'Enchanting', mode = 'Enchanting', gmst = 'sEnchanting', choice = 7,
      label = 'Enchanting', verb = 'enchant an item for the stranger', asks = 'to have an item enchanted' },
}

local byId = {}
for _, service in ipairs(M.SERVICES) do
    byId[service.id] = service
end
M.byId = byId

-- Ids of the services the NPC offers, in vanilla's order
-- @param offered the record's servicesOffered table
function M.offered(offered)
    local list = {}
    for _, service in ipairs(M.SERVICES) do
        if offered and offered[service.key] then
            list[#list + 1] = service.id
        end
    end
    return list
end

-- Words that suggest a reply offers a service; the NPC-offer check only runs on replies that contain one
local serviceWords = {
    'wares', 'goods', 'buy', 'sell', 'trade', 'barter', 'merchandise', 'shop', 'price', 'prices', 'train', 'training',
    'teach', 'lesson', 'lessons', 'instruct', 'travel', 'passage', 'strider', 'boat', 'ship', 'take you', 'transport',
    'spell', 'spells', 'enchant', 'enchanting', 'repair', 'mend', 'fix',
}

function M.mentionsService(text)
    local lower = (text or ''):lower()
    for _, word in ipairs(serviceWords) do
        if lower:find('%f[%a]' .. word .. '%f[%A]') then
            return true
        end
    end
    return false
end

local function label(service)
    local ok, value = pcall(core.getGMST, service.gmst)
    return (ok and type(value) == 'string' and value ~= '') and value or service.label
end

-- After the reply: "Barter" / "Not now"; the first opens the vanilla window over the dialogue
local function offer(game, turn, service)
    game.choices(turn, 'after', {
        { id = 'yes', label = label(service) },
        { id = 'no', label = game.l10n('notNowChoice') },
    }, function(choiceId)
        if choiceId == 'yes' then
            game.openWindow(service.mode, turn.npc)
        end
        game.finishTurn()
    end)
end

-- Vanilla's refusal line for this service, or nil if the NPC would provide it
local function refused(game, turn, service)
    local ok, text = pcall(llm.serviceRefusal, turn.npc, service.choice)
    if not ok then
        print('LLM service refusal: ' .. tostring(text))
        return nil
    end
    return text
end

local function parse(ctx, answer)
    for _, id in ipairs(ctx.services) do
        if id == answer.service then
            return { service = byId[id] }
        end
    end
    return nil
end

local function wordList(words)
    if #words == 1 then
        return words[1]
    end
    return table.concat(words, ', ', 1, #words - 1) .. ' or ' .. words[#words]
end

-- What the NPC's services are, in words: "trade with Vennin, sell Vennin spells or train Vennin"
local function serviceVerbs(ctx)
    local verbs = {}
    for _, id in ipairs(ctx.services) do
        verbs[#verbs + 1] = (byId[id].verb:gsub('the stranger', ctx.playerName))
    end
    return wordList(verbs)
end

-- How the player asks for them: "to see or buy their wares or for passage or a ride to another town"
local function serviceAsks(ctx)
    local asks = {}
    for _, id in ipairs(ctx.services) do
        asks[#asks + 1] = byId[id].asks
    end
    return wordList(asks)
end

M.intents = {
    {
        name = 'service',
        params = { 'service' },
        describe = function(ctx)
            return ctx.playerName .. ' asks ' .. ctx.npcName .. ' for one of their services: ' .. serviceAsks(ctx)
                .. '. Asking where to find something elsewhere does not count.'
        end,
        noneWords = { 'buy', 'travel' },
        available = function(ctx)
            return #ctx.services > 0
        end,
        parse = parse,
        run = function(game, turn, params)
            local service = params.service
            turn.serviceUsed = true
            local refusal = refused(game, turn, service)
            if refusal then
                game.happened(turn, string.format('%s refuses to %s. In the original story, they say: "%s"',
                    turn.npcName, service.verb, game.expand(refusal, turn.npc)))
                return
            end
            game.happened(turn, string.format('%s agrees to %s.', turn.npcName, service.verb))
            offer(game, turn, service)
        end,
    },
}

M.proposals = {
    {
        name = 'offer_service',
        params = { 'service' },
        describe = function(ctx)
            return ctx.npcName .. ' offers to ' .. serviceVerbs(ctx) .. ' now, for example inviting ' .. ctx.playerName
                .. ' to see their wares. Merely mentioning their trade, or refusing, does not count.'
        end,
        available = function(ctx)
            return #ctx.services > 0 and not ctx.serviceUsed and M.mentionsService(ctx.reply)
        end,
        parse = parse,
        run = function(game, turn, params)
            if not refused(game, turn, params.service) then
                offer(game, turn, params.service)
            end
        end,
    },
}

-- For player.lua: the services this NPC offers
function M.forNpc(npc)
    local ok, record = pcall(types.NPC.record, npc)
    return M.offered(ok and record and record.servicesOffered or nil)
end

return M
