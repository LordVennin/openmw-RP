-- Lorebook in SillyTavern's World Info format: every llm/lore/*.json file in any data folder is loaded, so mods
-- can add lore and files can be edited in SillyTavern's World Info editor. An entry is included when one of its
-- keys is mentioned (whole word, any case) in the texts given, which include the scene's place line so the
-- current town or region triggers its own entry; constant entries are always included. Entries are capped by the
-- token budget, highest `order` first.

local vfs = require('openmw.vfs')

local budget = require('scripts.llm.budget')
local json = require('scripts.llm.json')

local M = {}

local entries = nil

local function escapePattern(s)
    return (s:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0'))
end

local function readFile(path)
    local file = vfs.open(path)
    if not file then
        return nil
    end
    local content = file:read('*a')
    file:close()
    return content
end

-- Normalizes one World Info entry; returns nil for disabled or empty ones
local function normalize(raw, source)
    if type(raw) ~= 'table' or raw.disable or type(raw.content) ~= 'string' or not raw.content:find('%S') then
        return nil
    end
    local keys = {}
    for _, key in ipairs(type(raw.key) == 'table' and raw.key or {}) do
        if type(key) == 'string' and key:find('%S') then
            keys[#keys + 1] = key:lower()
        end
    end
    if #keys == 0 and not raw.constant then
        return nil
    end
    return {
        keys = keys,
        content = raw.content,
        constant = raw.constant == true,
        order = tonumber(raw.order) or 100,
        name = raw.comment or keys[1] or source,
    }
end

function M.load()
    entries = {}
    for path in vfs.pathsWithPrefix('llm/lore') do
        if path:lower():match('%.json$') then
            local content = readFile(path)
            local ok, data = pcall(json.decode, content or '')
            if ok and type(data) == 'table' and type(data.entries) == 'table' then
                for _, raw in pairs(data.entries) do
                    local entry = normalize(raw, path)
                    if entry then
                        entries[#entries + 1] = entry
                    end
                end
            else
                print('LLM: could not parse lorebook ' .. path .. ': ' .. tostring(data))
            end
        end
    end
    table.sort(entries, function(a, b)
        if a.order ~= b.order then
            return a.order > b.order
        end
        return a.name < b.name
    end)
    return entries
end

local function triggered(entry, haystack)
    if entry.constant then
        return true
    end
    for _, key in ipairs(entry.keys) do
        if haystack:find('%f[%w]' .. escapePattern(key) .. '%f[%W]') then
            return true
        end
    end
    return false
end

-- @param texts strings to look for keys in
-- @param limits table from budget.fromContextSize
-- @return the "[Lore]" note, or nil
function M.build(texts, limits)
    if not entries then
        M.load()
    end
    local haystack = table.concat(texts, '\n'):lower()
    local parts = {}
    local used = 0
    for _, entry in ipairs(entries) do
        if #parts >= limits.maxLoreEntries then
            break
        end
        if triggered(entry, haystack) then
            local cost = budget.estimateTokens(entry.content)
            if used + cost <= limits.loreTokens then
                parts[#parts + 1] = '- ' .. entry.content:gsub('%s+', ' ')
                used = used + cost
            end
        end
    end
    if #parts == 0 then
        return nil
    end
    return '[Lore]\n' .. table.concat(parts, '\n')
end

return M
