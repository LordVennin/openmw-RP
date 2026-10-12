-- Attached to an NPC (CUSTOM script) the first time an AI conversation changes their AI ratings. Only a script on
-- the NPC itself may change its Fight and Flee, which is what vanilla Taunt and Intimidate do; the engine's own AI
-- then decides whether the NPC attacks.

local self = require('openmw.self')
local types = require('openmw.types')

local function modify(stat, delta)
    if delta and delta ~= 0 then
        stat.base = math.max(0, math.min(100, stat.base + delta))
    end
end

return {
    eventHandlers = {
        LLMModAI = function(data)
            modify(types.Actor.stats.ai.fight(self), data.fight)
            modify(types.Actor.stats.ai.flee(self), data.flee)
        end,
    },
}
