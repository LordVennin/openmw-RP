-- Builds the "[Scene]" note: a short, capped description of where the conversation happens and what is around.
-- It is rebuilt for every request and never stored in the history. Rules that keep it digestible for small
-- models: closest things first, a hard cap per line, words instead of numbers, display names instead of ids.

local core = require('openmw.core')
local nearby = require('openmw.nearby')
local types = require('openmw.types')
local calendar = require('openmw_aux.calendar')

local budget = require('scripts.llm.budget')

local M = {}

local numberWords = { 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine' }

local function count(n)
    return numberWords[n] or tostring(n)
end

-- "a" or "an" followed by the word
local function article(word)
    return (word:match('^[AEIOUaeiou]') and 'an ' or 'a ') .. word
end

local function joinList(items)
    if #items == 0 then
        return nil
    elseif #items == 1 then
        return items[1]
    end
    return table.concat(items, ', ', 1, #items - 1) .. ' and ' .. items[#items]
end

local function recordOf(obj)
    local ok, record = pcall(function()
        return obj.type.record(obj)
    end)
    return ok and record or nil
end

local function nameOf(obj)
    local record = recordOf(obj)
    return record and record.name or nil
end

local function distanceWords(a, b)
    local meters = (a.position - b.position):length() / budget.UNITS_PER_METER
    if meters < 4 then
        return 'right next to you'
    elseif meters < 12 then
        return 'nearby'
    end
    return 'across the room'
end

local function raceName(raceId)
    local ok, race = pcall(types.NPC.races.record, raceId)
    return ok and race and race.name or nil
end

local function className(classId)
    local ok, class = pcall(types.NPC.classes.record, classId)
    return ok and class and class.name or nil
end

local function cellName(cell)
    if cell == nil then
        return nil
    end
    if cell.name and cell.name ~= '' then
        return cell.name
    end
    if cell.region then
        local region = core.regions.records[cell.region]
        if region and region.name ~= '' then
            return 'the wilderness of ' .. region.name
        end
    end
    return 'the wilderness'
end

local function partOfDay(hour)
    if hour < 5 then
        return 'night'
    elseif hour < 12 then
        return 'morning'
    elseif hour < 17 then
        return 'afternoon'
    elseif hour < 21 then
        return 'evening'
    end
    return 'night'
end

-- "friendly", "neutral"... from a 0-100 disposition
function M.dispositionWords(value)
    if value >= 80 then
        return 'very fond of the stranger'
    elseif value >= 60 then
        return 'friendly'
    elseif value >= 35 then
        return 'neutral'
    elseif value >= 15 then
        return 'unfriendly'
    end
    return 'hostile'
end

local clothingSlots = { 'Robe', 'Cuirass', 'Shirt', 'Pants', 'Skirt', 'Helmet' }

local function wearing(actor)
    local ok, equipment = pcall(types.Actor.getEquipment, actor)
    if not ok or not equipment then
        return nil
    end
    local names, seen = {}, {}
    for _, slotName in ipairs(clothingSlots) do
        local item = equipment[types.Actor.EQUIPMENT_SLOT[slotName]]
        local name = item and nameOf(item)
        if name and not seen[name] then
            seen[name] = true
            names[#names + 1] = name:lower()
            if #names == 3 then
                break
            end
        end
    end
    return joinList(names)
end

local function armedState(actor)
    local ok, equipment = pcall(types.Actor.getEquipment, actor)
    local weapon = ok and equipment and equipment[types.Actor.EQUIPMENT_SLOT.CarriedRight]
    local weaponName = weapon and nameOf(weapon)
    local stance = types.Actor.getStance(actor)
    if stance == types.Actor.STANCE.Spell then
        return 'hands raised, ready to cast a spell'
    elseif stance == types.Actor.STANCE.Weapon then
        return weaponName and ('holding a drawn ' .. weaponName:lower()) or 'fists raised'
    elseif weaponName then
        return 'carrying a sheathed ' .. weaponName:lower()
    end
    return 'unarmed'
end

local function healthState(actor)
    local health = types.Actor.stats.dynamic.health(actor)
    if health.base > 0 and health.current / health.base < 0.35 then
        return 'badly hurt'
    end
    return nil
end

local function describePerson(actor)
    if types.NPC.objectIsInstance(actor) then
        local record = types.NPC.record(actor)
        local details = { raceName(record.race) }
        local class = className(record.class)
        if class and class:lower() ~= record.name:lower() then
            details[#details + 1] = class
        end
        local text = record.name
        if #details > 0 then
            text = text .. ' (' .. table.concat(details, ', ') .. ')'
        end
        return text
    end
    local name = nameOf(actor)
    return name and article(name:lower()) or nil
end

local function factionsOf(actor)
    local result = {}
    local ok, factions = pcall(types.NPC.getFactions, actor)
    if not ok or not factions then
        return result
    end
    for _, factionId in ipairs(factions) do
        local faction = core.factions.records[factionId]
        if faction and not faction.hidden then
            local rank = types.NPC.getFactionRank(actor, factionId)
            local rankName = faction.ranks[rank] and faction.ranks[rank].name
            result[#result + 1] = rankName and rankName ~= '' and (faction.name .. ' (' .. rankName .. ')')
                or faction.name
        end
    end
    return result
end

-- Objects of `list` in the same cell as `center`, within `radius`, closest first
local function closest(list, center, radius, filter)
    local found = {}
    for _, obj in ipairs(list) do
        if obj:isValid() and obj.cell == center.cell and (not filter or filter(obj)) then
            local distance = (obj.position - center.position):length()
            if distance <= radius then
                found[#found + 1] = { obj = obj, distance = distance }
            end
        end
    end
    table.sort(found, function(a, b)
        return a.distance < b.distance
    end)
    return found
end

local function placeLine(npc)
    local cell = npc.cell
    local line = 'Place: ' .. cellName(cell)
    local indoors = not cell.isExterior and not cell:hasTag('QuasiExterior')
    line = line .. (indoors and ' (indoors).' or ' (outdoors).')
    if cell.region then
        local region = core.regions.records[cell.region]
        if region and region.name ~= '' and not line:find(region.name, 1, true) then
            line = line .. ' ' .. region.name .. '.'
        end
    end
    return line, indoors
end

local function timeLine(cell, indoors)
    local t = calendar.formatGameTime('*t')
    local line = string.format('Time: %s, %d %s.', partOfDay(t.hour), t.day, calendar.monthName(t.month))
    if not indoors then
        local ok, weather = pcall(core.weather.getCurrent, cell)
        if ok and weather and weather.name then
            line = line .. ' Weather: ' .. weather.name:lower() .. '.'
        end
    end
    return line
end

local function npcLine(npc, player)
    local record = types.NPC.record(npc)
    local parts = { armedState(npc) }
    local clothes = wearing(npc)
    if clothes then
        parts[#parts + 1] = 'wearing ' .. clothes
    end
    local hurt = healthState(npc)
    if hurt then
        parts[#parts + 1] = hurt
    end
    local line = 'You (' .. record.name .. '): ' .. table.concat(parts, ', ') .. '.'
    local ok, disposition = pcall(types.NPC.getDisposition, npc, player)
    if ok and disposition then
        line = line .. ' Mood toward the stranger: ' .. M.dispositionWords(disposition) .. '.'
    end
    return line
end

local function strangerLine(player)
    local record = types.NPC.record(player)
    local who = article((raceName(record.race) or 'stranger') .. ' ' .. (record.isMale and 'man' or 'woman'))
    local class = className(record.class)
    if class then
        who = who .. ', ' .. article(class:lower())
    end
    local parts = { who, armedState(player) }
    local clothes = wearing(player)
    if clothes then
        parts[#parts + 1] = 'wearing ' .. clothes
    end
    local hurt = healthState(player)
    if hurt then
        parts[#parts + 1] = hurt
    end
    local line = 'The stranger: ' .. table.concat(parts, ', ') .. '.'
    local factions = factionsOf(player)
    if #factions > 0 then
        line = line .. ' Member of ' .. joinList(factions) .. '.'
    end
    local ok, crime = pcall(types.Player.getCrimeLevel, player)
    if ok and crime and crime > 0 then
        line = line .. ' Wanted by the law.'
    end
    return line
end

local function peopleLine(npc, player, limits)
    local entries = {}
    local creatureCounts, creatureOrder = {}, {}
    for _, entry in ipairs(closest(nearby.actors, npc, limits.sceneRadius, function(a)
        return a.id ~= npc.id and a.id ~= player.id
    end)) do
        local actor = entry.obj
        local ok, description = pcall(describePerson, actor)
        if ok and description then
            local dead = types.Actor.isDead(actor)
            if types.NPC.objectIsInstance(actor) then
                local text = dead and ('the corpse of ' .. description) or description
                entries[#entries + 1] = text .. ' ' .. distanceWords(actor, npc)
            else
                local key = (dead and 'dead ' or '') .. description
                if not creatureCounts[key] then
                    creatureOrder[#creatureOrder + 1] = key
                    creatureCounts[key] = 0
                end
                creatureCounts[key] = creatureCounts[key] + 1
            end
        end
        if #entries >= limits.maxPeople then
            break
        end
    end
    for _, key in ipairs(creatureOrder) do
        if #entries >= limits.maxPeople then
            break
        end
        local n = creatureCounts[key]
        entries[#entries + 1] = n > 1 and (count(n) .. ' ' .. key:gsub('^an? ', '') .. 's') or key
    end
    if #entries == 0 then
        return nil
    end
    return 'People nearby: ' .. table.concat(entries, '; ') .. '.'
end

local function doorsLine(npc, limits)
    local destinations, seen = {}, {}
    for _, entry in ipairs(closest(nearby.doors, npc, limits.sceneRadius, types.Door.isTeleport)) do
        local ok, cell = pcall(types.Door.destCell, entry.obj)
        local name = ok and cellName(cell)
        if name and not seen[name] then
            seen[name] = true
            destinations[#destinations + 1] = name
            if #destinations >= limits.maxDoors then
                break
            end
        end
    end
    if #destinations == 0 then
        return nil
    end
    return 'Ways out: doors to ' .. table.concat(destinations, '; ') .. '.'
end

local function ownerName(obj)
    local owner = obj.owner
    if owner and owner.recordId then
        local record = types.NPC.records[owner.recordId]
        return record and record.name or nil
    elseif owner and owner.factionId then
        local faction = core.factions.records[owner.factionId]
        return faction and ('the ' .. faction.name) or nil
    end
    return nil
end

local function thingsLine(npc, limits)
    local candidates = closest(nearby.items, npc, limits.sceneRadius)
    for _, entry in ipairs(closest(nearby.containers, npc, limits.sceneRadius)) do
        candidates[#candidates + 1] = entry
    end
    table.sort(candidates, function(a, b)
        return a.distance < b.distance
    end)

    local counts, order = {}, {}
    for _, entry in ipairs(candidates) do
        local obj = entry.obj
        local name = nameOf(obj)
        local isContainer = types.Container.objectIsInstance(obj)
        -- Harvestable plants are containers too; they are just noise here
        local organic = isContainer and types.Container.record(obj).isOrganic
        if name and name ~= '' and not organic then
            local key = name:lower()
            if isContainer then
                local details = {}
                if types.Lockable.isLocked(obj) then
                    key = 'a locked ' .. name:lower()
                else
                    key = article(name:lower())
                end
                local owner = ownerName(obj)
                if owner then
                    details[#details + 1] = 'belongs to ' .. owner
                end
                if #details > 0 then
                    key = key .. ' (' .. table.concat(details, ', ') .. ')'
                end
            end
            if not counts[key] then
                if #order >= limits.maxThings then
                    break
                end
                order[#order + 1] = key
                counts[key] = 0
            end
            counts[key] = counts[key] + obj.count
        end
    end
    if #order == 0 then
        return nil
    end
    local things = {}
    for _, key in ipairs(order) do
        local n = counts[key]
        if n > 1 then
            things[#things + 1] = key:gsub('^an? ', '') .. ' (' .. n .. ')'
        elseif key:match('^an? ') then
            things[#things + 1] = key
        else
            things[#things + 1] = article(key)
        end
    end
    return 'Things in view: ' .. table.concat(things, '; ') .. '.'
end

-- @param npc the NPC being talked to
-- @param player the player object
-- @param detail 'off', 'brief' or 'full'
-- @param limits table from budget.fromContextSize
-- @return the scene note, or nil when detail is 'off'
function M.build(npc, player, detail, limits)
    if detail == 'off' then
        return nil
    end
    local lines = { '[Scene]' }
    local function add(builder, ...)
        local ok, line = pcall(builder, ...)
        if ok and line then
            lines[#lines + 1] = line
        elseif not ok then
            print('LLM scene: ' .. tostring(line))
        end
    end
    local ok, place, indoors = pcall(placeLine, npc)
    if ok then
        lines[#lines + 1] = place
    end
    add(timeLine, npc.cell, ok and indoors)
    add(npcLine, npc, player)
    add(strangerLine, player)
    if detail == 'full' then
        add(peopleLine, npc, player, limits)
        add(doorsLine, npc, limits)
        add(thingsLine, npc, limits)
    end
    return budget.truncate(table.concat(lines, '\n'), limits.sceneTokens)
end

return M
