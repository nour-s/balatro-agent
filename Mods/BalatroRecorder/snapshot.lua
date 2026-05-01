-- Snapshot: captures the current game state as a plain Lua table.

local Snapshot = {}

function Snapshot.round_resources()
    if not (G and G.GAME) then return nil end
    local cr = G.GAME.current_round or {}
    return {
        hands_left    = G.GAME.current_round and G.GAME.current_round.hands_left or 0,
        discards_left = G.GAME.current_round and G.GAME.current_round.discards_left or 0,
    }
end

function Snapshot.economy()
    if not (G and G.GAME) then return nil end
    return {
        dollars  = G.GAME.dollars or 0,
        interest = G.GAME.interest_amount or 0,
    }
end

function Snapshot.blind_state()
    if not (G and G.GAME and G.GAME.blind) then return nil end
    local b = G.GAME.blind
    return {
        key         = b.config and b.config.blind and b.config.blind.key,
        name        = b.name,
        chips       = b.chips,
        chips_needed= b.chips,
        boss        = b.boss,
    }
end

function Snapshot.hand_info()
    if not (G and G.GAME and G.GAME.current_round) then return nil end
    local cr = G.GAME.current_round
    return {
        handname = cr.current_hand and cr.current_hand.handname,
        chips    = cr.current_hand and cr.current_hand.chips,
        mult     = cr.current_hand and cr.current_hand.mult,
    }
end

-- Compact state for state_before / state_after
function Snapshot.compact()
    if not (G and G.GAME) then return {} end
    local cr  = G.GAME.current_round or {}
    local enc = require("encoder")
    return {
        state         = G.STATE and require("recorder").state_name(G.STATE),
        ante          = G.GAME.round_resets and G.GAME.round_resets.ante or G.GAME.ante,
        round         = G.GAME.round or 0,
        hands_left    = cr.hands_left or 0,
        discards_left = cr.discards_left or 0,
        chips_scored  = G.GAME.chips or 0,
        chips_needed  = G.GAME.blind and G.GAME.blind.chips or 0,
        dollars       = G.GAME.dollars or 0,
        deck_size     = G.deck and #G.deck.cards or 0,
        joker_count   = G.jokers and #G.jokers.cards or 0,
        consumable_count = G.consumeables and #G.consumeables.cards or 0,
    }
end

-- Full joker graph with copy-relationships
function Snapshot.joker_graph()
    if not (G and G.jokers) then return {} end
    local enc = require("encoder")
    local jokers = enc.joker_list(G.jokers.cards)

    -- detect Blueprint (copies right neighbor) and Brainstorm (copies leftmost)
    for i, j_raw in ipairs(G.jokers.cards or {}) do
        local key = (j_raw.config and j_raw.config.center and j_raw.config.center.key)
                 or (j_raw.ability and j_raw.ability.name) or ""
        local jenc = jokers[i]
        if jenc then
            if string.find(string.lower(key), "blueprint") then
                -- copies right neighbor
                local target_raw = G.jokers.cards[i + 1]
                if target_raw then
                    jenc.copies_pos  = i  -- 0-based
                    jenc.copies_key  = (target_raw.config and target_raw.config.center and target_raw.config.center.key)
                end
            elseif string.find(string.lower(key), "brainstorm") then
                -- copies leftmost joker
                local target_raw = G.jokers.cards[1]
                if target_raw and target_raw ~= j_raw then
                    jenc.copies_pos = 0
                    jenc.copies_key = (target_raw.config and target_raw.config.center and target_raw.config.center.key)
                end
            end
        end
    end
    return jokers
end

return Snapshot
