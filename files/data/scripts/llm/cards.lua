-- Loads SillyTavern character cards (V1 or V2 "chara_card_v2" JSON) from the VFS. A card for an NPC lives at
-- llm/cards/<record id>.json in any data folder, so mods can add or override cards.

local vfs = require('openmw.vfs')

local json = require('scripts.llm.json')

local M = {}

local cache = {}

local function readFile(path)
    local file = vfs.open(path)
    if not file then
        return nil
    end
    local content = file:read('*a')
    file:close()
    return content
end

local function field(data, name)
    local value = data[name]
    if type(value) == 'string' and value:find('%S') then
        return value
    end
    return nil
end

-- Normalizes V1 (flat) and V2 (fields under `data`) cards
local function normalize(raw)
    local data = type(raw.data) == 'table' and raw.data or raw
    return {
        name = field(data, 'name'),
        description = field(data, 'description'),
        personality = field(data, 'personality'),
        scenario = field(data, 'scenario'),
        firstMes = field(data, 'first_mes'),
        mesExample = field(data, 'mes_example'),
        systemPrompt = field(data, 'system_prompt'),
        postHistoryInstructions = field(data, 'post_history_instructions'),
    }
end

-- Returns the hand-written card for an NPC record id, or nil
function M.load(recordId)
    recordId = recordId:lower()
    if cache[recordId] == nil then
        local path = 'llm/cards/' .. recordId .. '.json'
        local content = vfs.fileExists(path) and readFile(path)
        local card = false
        if content then
            local ok, raw = pcall(json.decode, content)
            if ok and type(raw) == 'table' then
                card = normalize(raw)
            else
                print('LLM: could not parse card ' .. path .. ': ' .. tostring(raw))
            end
        end
        cache[recordId] = card
    end
    return cache[recordId] or nil
end

-- Replaces SillyTavern macros in every text field of a card
function M.substitute(card, charName, userName)
    -- '%' is special in gsub replacement strings
    charName = charName:gsub('%%', '%%%%')
    userName = userName:gsub('%%', '%%%%')
    local result = {}
    for key, value in pairs(card) do
        if type(value) == 'string' then
            value = value:gsub('{{[cC][hH][aA][rR]}}', charName):gsub('{{[uU][sS][eE][rR]}}', userName)
            value = value:gsub('<BOT>', charName):gsub('<USER>', userName)
        end
        result[key] = value
    end
    return result
end

return M
