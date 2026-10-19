-- Directions to real places and people in the area. When the player asks the way ("where is the lighthouse?"), the
-- doors and NPCs in the active cells whose names match the question are described from where the NPC stands: a
-- compass direction and a distance in words, so the reply points the right way instead of inventing a route.
-- Topics with vanilla answers (scripts/llm/knowledge.lua) and the lorebook cover the rest, as before.

local nearby = require('openmw.nearby')
local types = require('openmw.types')

local budget = require('scripts.llm.budget')

local M = {}

local MAX_MATCHES = 3

-- Phrases that ask for a place or a person's whereabouts
local askPatterns = {
    '%f[%a]where%f[%A]', '%f[%a]how do i get%f[%A]', '%f[%a]how can i get%f[%A]', '%f[%a]how to get%f[%A]',
    '%f[%a]way to%f[%A]', '%f[%a]find%f[%A]', '%f[%a]direction', '%f[%a]located%f[%A]', '%f[%a]lead me%f[%A]',
    '%f[%a]take me to%f[%A]', '%f[%a]show me the way%f[%A]',
}

function M.asksWay(line)
    local lower = (line or ''):lower()
    for _, pattern in ipairs(askPatterns) do
        if lower:find(pattern) then
            return true
        end
    end
    return false
end

-- Words that name a kind of place rather than a particular one: "house" alone doesn't pick Fargoth's House
local genericWords = {
    the = true, ['and'] = true, ['of'] = true, house = true, shack = true, hut = true, room = true, rooms = true,
    cellar = true, basement = true, upper = true, lower = true, level = true, hall = true, tower = true, manor = true,
    store = true, shop = true, office = true, building = true, home = true, ['in'] = true, ['to'] = true,
}

local function words(text)
    local list = {}
    for word in text:lower():gsub("'s%f[%A]", ''):gmatch('%a+') do
        if #word >= 3 then
            list[#list + 1] = word
        end
    end
    return list
end

-- How well `name` matches the question: the number of its words that appear in it, or 0 unless at least one of
-- them is particular to this place
function M.matchScore(name, questionWords)
    local score, particular = 0, false
    for _, word in ipairs(words(name)) do
        if questionWords[word] then
            score = score + 1
            if not genericWords[word] then
                particular = true
            end
        end
    end
    return particular and score or 0
end

local compassNames = { 'north', 'north-east', 'east', 'south-east', 'south', 'south-west', 'west', 'north-west' }

-- Compass direction of an offset in game units (x east, y north)
function M.compass(dx, dy)
    local degrees = math.deg(math.atan2(dx, dy)) % 360
    return compassNames[math.floor((degrees + 22.5) / 45) % 8 + 1]
end

function M.distanceWords(meters)
    if meters < 10 then
        return 'right here'
    elseif meters < 40 then
        return 'a few steps away'
    elseif meters < 150 then
        return 'a short walk away'
    elseif meters < 400 then
        return 'across town'
    end
    return 'a long way off'
end

-- "Arrille's Tradehouse" from "Seyda Neen, Arrille's Tradehouse"
local function placeName(cellName)
    return cellName:match(',%s*(.+)$') or cellName
end

-- Where `target` is, seen from `from`: "a short walk away to the north-west"
local function whereIs(from, target)
    local dx, dy = target.x - from.x, target.y - from.y
    local meters = math.sqrt(dx * dx + dy * dy) / budget.UNITS_PER_METER
    local distance = M.distanceWords(meters)
    if meters < 10 then
        return distance
    end
    return distance .. ' to the ' .. M.compass(dx, dy)
end

-- Ranks the candidates ({ name, position, kind }) against the question; best first, at most MAX_MATCHES
function M.match(candidates, line)
    local questionWords = {}
    for _, word in ipairs(words(line)) do
        questionWords[word] = true
    end
    local found = {}
    for _, candidate in ipairs(candidates) do
        local score = M.matchScore(candidate.name, questionWords)
        if score > 0 then
            found[#found + 1] = { candidate = candidate, score = score }
        end
    end
    table.sort(found, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        return a.candidate.distance < b.candidate.distance
    end)
    local result = {}
    for i = 1, math.min(#found, MAX_MATCHES) do
        result[i] = found[i].candidate
    end
    return result
end

local LANDMARK_RADIUS = 30 -- meters

-- The nearest other named door to `match`, as a real landmark ("next to Arrille's Tradehouse"), or nil
function M.landmark(match, places)
    local best, bestDistance = nil, LANDMARK_RADIUS * budget.UNITS_PER_METER
    for _, place in ipairs(places) do
        if place.kind == 'door' and place.name ~= match.name then
            local dx, dy = place.position.x - match.position.x, place.position.y - match.position.y
            local distance = math.sqrt(dx * dx + dy * dy)
            if distance < bestDistance then
                best, bestDistance = place, distance
            end
        end
    end
    return best and best.name or nil
end

-- The "[Directions]" note for the matches, seen from `from` (the NPC's position), or nil
-- @param places every place in the area, for landmarks
function M.note(matches, from, places)
    if #matches == 0 then
        return nil
    end
    local lines = { '[Directions]', 'Where the places and people the stranger asks about are, from where you stand:' }
    for _, match in ipairs(matches) do
        local what = match.kind == 'door' and 'the door is ' or ''
        local line = '- ' .. match.name .. ': ' .. what .. whereIs(from, match.position)
        local landmark = M.landmark(match, places or {})
        if landmark then
            line = line .. ', near ' .. landmark
        end
        lines[#lines + 1] = line .. '.'
    end
    lines[#lines + 1] = 'Use these if the stranger asks the way: you know this area. Give only this direction, '
        .. 'distance and landmark; do not invent other landmarks.'
    return table.concat(lines, '\n')
end

-- Doors (by destination) and NPCs in the active cells; the nearest door to each destination
local function placesAround(npc, player)
    local list, doorIndex = {}, {}
    for _, door in ipairs(nearby.doors) do
        if door:isValid() and types.Door.isTeleport(door) then
            local ok, cell = pcall(types.Door.destCell, door)
            local cellName = ok and cell and cell.name
            if cellName and cellName ~= '' then
                local name = placeName(cellName)
                local distance = (door.position - npc.position):length()
                local existing = doorIndex[name]
                if not existing then
                    doorIndex[name] = { name = name, position = door.position, distance = distance, kind = 'door' }
                    list[#list + 1] = doorIndex[name]
                elseif distance < existing.distance then
                    existing.position, existing.distance = door.position, distance
                end
            end
        end
    end
    for _, actor in ipairs(nearby.actors) do
        if actor:isValid() and actor.id ~= npc.id and actor.id ~= player.id and types.NPC.objectIsInstance(actor)
            and not types.Actor.isDead(actor) then
            list[#list + 1] = { name = types.NPC.record(actor).name, position = actor.position,
                distance = (actor.position - npc.position):length(), kind = 'person' }
        end
    end
    return list
end

-- @return the "[Directions]" note for the player's line, or nil when it doesn't ask the way or nothing matches
function M.build(npc, player, line)
    if not M.asksWay(line) then
        return nil
    end
    local places = placesAround(npc, player)
    return M.note(M.match(places, line), npc.position, places)
end

return M
