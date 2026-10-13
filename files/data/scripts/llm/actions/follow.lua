-- Followers: asking an NPC to come along, wait, or go home. Whether they agree is decided by the game's rules in
-- scripts/llm/followers.lua; the reply comes first, then the player confirms with "Take X along" / "Never mind".
-- The global script keeps the follower registry and the AI packages.

local followers = require('scripts.llm.followers')

local M = {}

local reasons = {
    afraid = '%s agrees to follow the stranger, but only out of fear, and resents it.',
    rank = '%s agrees to follow, because the stranger outranks them.',
    likes = '%s agrees to come along: they like the stranger.',
    quest = "%s can't come along: they have their own business to attend to right now.",
    essential = "%s can't come along: they have their own business to attend to right now.",
    job = '%s likes the stranger, but refuses: they have work to do here and cannot leave their post.',
    dislikes = "%s refuses to follow: they don't like or trust the stranger enough.",
}

local function follow(game, turn)
    local convo = game.conversation(turn.npc)
    local ok, decision = pcall(followers.decideFor, turn.npc, game.player, convo.coerced)
    if not ok then
        print('LLM follow decision: ' .. tostring(decision))
        return
    end
    game.happened(turn, string.format(reasons[decision.reason], turn.npcName))
    if not decision.agrees then
        return
    end
    -- The reply comes first, so the player hears the NPC agree; the choice follows it
    game.choices(turn, 'after', {
        { id = 'yes', label = game.l10n('followChoice', { name = turn.npcName }) },
        { id = 'no', label = game.l10n('neverMindChoice') },
    }, function(choiceId)
        if choiceId == 'yes' then
            game.sendGlobal('LLMFollow', { npc = turn.npc, player = game.player, reason = decision.reason })
            game.setFollowerState(turn.npc, 'following', decision.reason)
            game.notice('followNotice', { name = turn.npcName })
            game.historyEvent(turn.npc, string.format('%s started following the stranger.', turn.npcName))
        else
            game.historyEvent(turn.npc,
                string.format('%s offered to come along, but the stranger decided against it.', turn.npcName))
        end
        game.finishTurn()
    end)
end

M.intents = {
    {
        name = 'follow',
        describe = function(ctx)
            return ctx.playerName .. ' asks ' .. ctx.npcName .. ' to come along with them or follow them.'
        end,
        noneWords = { 'follow' },
        available = function(ctx)
            return ctx.followerState ~= 'following'
        end,
        run = follow,
    },
    {
        name = 'wait',
        describe = function(ctx)
            return ctx.playerName .. ' asks ' .. ctx.npcName .. ' to wait or stay where they are.'
        end,
        noneWords = { 'wait' },
        available = function(ctx)
            return ctx.followerState == 'following'
        end,
        run = function(game, turn)
            game.sendGlobal('LLMWait', { npc = turn.npc, player = game.player })
            game.setFollowerState(turn.npc, 'waiting')
            game.notice('waitNotice', { name = turn.npcName })
            game.happened(turn, string.format('%s stops and will wait here for the stranger.', turn.npcName))
        end,
    },
    {
        name = 'dismiss',
        describe = function(ctx)
            return ctx.playerName .. ' tells ' .. ctx.npcName .. ' to stop following, go home, or leave their company.'
        end,
        available = function(ctx)
            return ctx.followerState == 'following' or ctx.followerState == 'waiting'
        end,
        run = function(game, turn)
            game.sendGlobal('LLMDismiss', { npc = turn.npc, player = game.player })
            game.setFollowerState(turn.npc, nil)
            game.notice('dismissNotice', { name = turn.npcName })
            game.happened(turn, string.format('%s stops travelling with the stranger and will head home.', turn.npcName))
            game.historyEvent(turn.npc, string.format('%s stopped following the stranger.', turn.npcName))
        end,
    },
}

return M
