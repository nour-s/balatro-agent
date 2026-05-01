-- Hooks: all event handler functions called from init.lua wrappers.

local rec  = require("recorder")
local snap = require("snapshot")
local enc  = require("encoder")

local Hooks = {}

-- ───────────────────────────────────────────────
-- Run lifecycle
-- ───────────────────────────────────────────────

function Hooks.on_run_start()
    if not (G and G.GAME) then return end
    local seed   = G.GAME.pseudorandom and G.GAME.pseudorandom.seed or "unknown"
    local back   = G.GAME.selected_back
    local back_key = back and back.config and back.config.center and back.config.center.key
    local stake  = G.GAME.stake or 1

    rec.open_run(tostring(seed))

    rec.emit("RUN_START", {
        state_before = {},
        action = {
            seed      = seed,
            deck_key  = back_key,
            stake     = stake,
            challenge = G.GAME.challenge and G.GAME.challenge.name,
        },
        resolution = {},
        state_after = snap.compact(),
    })

    -- full deck snapshot
    if G.deck then
        rec.emit("DECK_SNAPSHOT", {
            state_before = {},
            action = {},
            resolution = { cards = enc.deck(G.deck.cards) },
            state_after  = {},
        })
    end

    rec.emit("JOKER_GRAPH", {
        trigger     = "RUN_START",
        state_before= {},
        action      = {},
        resolution  = { jokers = snap.joker_graph() },
        state_after = {},
    })
end

function Hooks.on_game_over(won)
    local event = won and "GAME_WIN" or "GAME_OVER"
    local before = snap.compact()
    rec.emit(event, {
        state_before = before,
        action       = {},
        resolution   = {
            ante   = before.ante,
            round  = before.round,
            dollars= before.dollars,
        },
        state_after  = {},
    })
    rec.close_run()
end

-- ───────────────────────────────────────────────
-- State machine
-- ───────────────────────────────────────────────

function Hooks.on_state_change(from_id, to_id)
    rec.emit("STATE_CHANGE", {
        state_before = { state = rec.state_name(from_id), G_STATE = from_id },
        action       = {},
        resolution   = {},
        state_after  = { state = rec.state_name(to_id),   G_STATE = to_id  },
    })

    -- entering blind selection: log all available blinds
    if to_id == 7 then  -- BLIND_SELECT
        Hooks.on_blind_select_enter()
    end

    -- entering shop: log full inventory
    if to_id == 5 then  -- SHOP
        Hooks.on_shop_enter()
    end

    -- entering NEW_ROUND: log round start
    if to_id == 19 then  -- NEW_ROUND
        Hooks.on_round_start()
    end

    -- entering GAME_OVER
    if to_id == 4 then
        Hooks.on_game_over(false)
    end
end

-- ───────────────────────────────────────────────
-- Blind selection
-- ───────────────────────────────────────────────

local function encode_blind_option(key)
    if not key then return nil end
    local p = G.P_BLINDS and G.P_BLINDS[key]
    if not p then return { key = key } end
    return {
        key   = key,
        name  = p.name,
        chips = G.GAME and G.GAME.blind_on_deck and G.GAME.blind_on_deck == key
                    and G.GAME.blind and G.GAME.blind.chips or p.chips,
    }
end

local function tag_for_blind(blind_key)
    -- tags are per-ante; we read the current pending tags list
    if not (G and G.tags) then return nil end
    for _, t in ipairs(G.tags or {}) do
        if t.config and t.config.type then
            return t.key
        end
    end
    return nil
end

function Hooks.on_blind_select_enter()
    if not (G and G.GAME) then return end
    -- read currently offered blinds from G.blind_select UI or G.GAME state
    local ante = G.GAME.round_resets and G.GAME.round_resets.ante or G.GAME.ante or 0

    local boss_reroll_available = false
    local boss_reroll_cost = 0
    if G.GAME.current_round then
        boss_reroll_available = G.GAME.current_round.reroll_boss_cost ~= nil
        boss_reroll_cost = G.GAME.current_round.reroll_boss_cost or 0
    end

    -- read the three blind keys from G.GAME.blind_on_deck or the blind config
    local small_key = "bl_small"
    local big_key   = "bl_big"
    local boss_key  = G.GAME.boss_blind_on_deck or (G.GAME.round_resets and G.GAME.round_resets.blind_states and G.GAME.round_resets.blind_states.Boss and G.GAME.round_resets.blind_states.Boss.key)

    rec.emit("BLIND_OPTIONS", {
        state_before = snap.compact(),
        action       = {},
        resolution   = {
            ante    = ante,
            small   = { key = small_key },
            big     = { key = big_key   },
            boss    = { key = boss_key  },
            boss_reroll_available = boss_reroll_available,
            boss_reroll_cost      = boss_reroll_cost,
        },
        state_after  = {},
    })
end

function Hooks.on_blind_selected(e)
    if not (G and G.GAME) then return end
    local blind = G.GAME.blind
    if not blind then return end
    local before = snap.compact()
    rec.emit("ROUND_START", {
        state_before = before,
        action       = { blind_key = blind.config and blind.config.blind and blind.config.blind.key },
        resolution   = {
            blind_name  = blind.name,
            chips_needed= blind.chips,
            boss        = blind.boss,
        },
        state_after  = snap.compact(),
    })
    if blind.boss then
        rec.emit("BOSS_BLIND_ACTIVE", {
            state_before = before,
            action       = {},
            resolution   = {
                key    = blind.config and blind.config.blind and blind.config.blind.key,
                name   = blind.name,
                effect = blind.config and blind.config.blind and blind.config.blind.boss_colour and "boss_effect",
            },
            state_after  = snap.compact(),
        })
    end
    rec.emit("JOKER_GRAPH", {
        trigger     = "ROUND_START",
        state_before= {},
        action      = {},
        resolution  = { jokers = snap.joker_graph() },
        state_after = {},
    })
end

function Hooks.on_blind_skipped(e)
    rec.emit("BLIND_OPTIONS", {
        state_before = snap.compact(),
        action       = { skipped = true },
        resolution   = { tag_earned = nil },  -- tag is computed post-skip
        state_after  = {},
    })
end

function Hooks.on_boss_rerolled(e)
    rec.emit("BOSS_REROLL", {
        state_before = snap.compact(),
        action       = {},
        resolution   = {},
        state_after  = snap.compact(),
    })
end

-- ───────────────────────────────────────────────
-- Round start
-- ───────────────────────────────────────────────

function Hooks.on_round_start()
    rec.emit("ROUND_RESOURCES", {
        state_before = {},
        action       = { trigger = "ROUND_START" },
        resolution   = snap.round_resources(),
        state_after  = snap.compact(),
    })
end

-- ───────────────────────────────────────────────
-- Hand played
-- ───────────────────────────────────────────────

function Hooks.on_before_play()
    -- called synchronously before cards are moved; capture pre-play state
    if not (G and G.hand) then return end
    BREC.state_before_hand = snap.compact()
    BREC.play_cards = {}
    for _, c in ipairs(G.hand.highlighted or {}) do
        table.insert(BREC.play_cards, enc.card(c))
    end
    -- start scoring chain capture
    BREC.scoring_active = true
    BREC.scoring_chain  = {}
    BREC.scoring_base   = {
        hand_type  = nil,
        base_chips = 0,
        base_mult  = 0,
    }
end

function Hooks.on_hand_result(hand_type, final_chips, final_mult, final_score)
    -- called from evaluate_play wrapper after scoring completes
    BREC.scoring_active = false
    local after = snap.compact()

    rec.emit("HAND_PLAYED", {
        state_before = BREC.state_before_hand,
        action       = { cards = BREC.play_cards },
        resolution   = {},
        state_after  = after,
    })

    rec.emit("HAND_RESOLUTION", {
        state_before = BREC.state_before_hand,
        action       = {},
        resolution   = {
            hand_type    = hand_type,
            base         = BREC.scoring_base,
            joker_chain  = BREC.scoring_chain,
            final        = {
                chips = final_chips,
                mult  = final_mult,
                score = final_score,
            },
            final_score  = after.chips_scored,
        },
        state_after  = after,
    })

    rec.emit("ROUND_RESOURCES", {
        state_before = BREC.state_before_hand,
        action       = { trigger = "AFTER_HAND" },
        resolution   = snap.round_resources(),
        state_after  = after,
    })

    BREC.state_before_hand = nil
    BREC.play_cards = nil
end

-- ───────────────────────────────────────────────
-- Discard
-- ───────────────────────────────────────────────

function Hooks.on_before_discard()
    if not (G and G.hand) then return end
    BREC.state_before_discard = snap.compact()
    BREC.discard_cards = {}
    for _, c in ipairs(G.hand.highlighted or {}) do
        table.insert(BREC.discard_cards, enc.card(c))
    end
end

function Hooks.on_after_discard()
    local after = snap.compact()
    rec.emit("CARDS_DISCARDED", {
        state_before = BREC.state_before_discard,
        action       = { cards = BREC.discard_cards },
        resolution   = {},
        state_after  = after,
    })
    rec.emit("ROUND_RESOURCES", {
        state_before = BREC.state_before_discard,
        action       = { trigger = "AFTER_DISCARD" },
        resolution   = snap.round_resources(),
        state_after  = after,
    })
    BREC.state_before_discard = nil
    BREC.discard_cards = nil
end

-- ───────────────────────────────────────────────
-- Scoring chain capture (called by eval_card wrapper)
-- ───────────────────────────────────────────────

function Hooks.on_joker_eval(joker_card, context, result, chips_before, mult_before, chips_after, mult_after)
    if not BREC.scoring_active then return end
    local key = joker_card.config and joker_card.config.center and joker_card.config.center.key
             or (joker_card.ability and joker_card.ability.name) or "unknown"
    local pos = 0
    if G.jokers then
        for i, j in ipairs(G.jokers.cards) do
            if j == joker_card then pos = i - 1; break end
        end
    end
    local step = {
        source     = key,
        pos        = pos,
        chips_delta= chips_after - chips_before,
        mult_delta = mult_after  - mult_before,
    }
    -- detect x_mult (if mult grew multiplicatively)
    if result and result.jokers and result.jokers.Xmult_mod then
        step.xmult = result.jokers.Xmult_mod
    end
    if step.chips_delta ~= 0 or step.mult_delta ~= 0 or step.xmult then
        table.insert(BREC.scoring_chain, step)
    end
end

-- ───────────────────────────────────────────────
-- Round won/lost
-- ───────────────────────────────────────────────

function Hooks.on_round_won()
    local before = snap.compact()
    rec.emit("ROUND_WON", {
        state_before = before,
        action       = {},
        resolution   = {
            chips_scored  = before.chips_scored,
            chips_needed  = before.chips_needed,
            dollars_after = before.dollars,
        },
        state_after  = snap.compact(),
    })
end

function Hooks.on_round_lost()
    local before = snap.compact()
    rec.emit("ROUND_LOST", {
        state_before = before,
        action       = {},
        resolution   = {
            chips_scored = before.chips_scored,
            chips_needed = before.chips_needed,
        },
        state_after  = snap.compact(),
    })
end

-- ───────────────────────────────────────────────
-- Shop
-- ───────────────────────────────────────────────

function Hooks.on_shop_enter()
    local slots = enc.shop_inventory()
    local reroll_cost = G.GAME and G.GAME.current_round and G.GAME.current_round.reroll_cost or 5
    rec.emit("SHOP_INVENTORY", {
        state_before = snap.compact(),
        action       = { reroll_number = 0, reroll_cost = reroll_cost },
        resolution   = { slots = slots },
        state_after  = snap.compact(),
    })
    rec.emit("CONSUMABLE_SNAPSHOT", {
        state_before = snap.compact(),
        action       = { trigger = "SHOP_ENTER" },
        resolution   = { consumables = enc.consumable_list(G.consumeables and G.consumeables.cards) },
        state_after  = {},
    })
end

function Hooks.on_shop_reroll()
    local before = snap.compact()
    -- money change will be emitted by ease_dollars wrapper
    BREC.money_source = "SHOP_REROLL"
    -- after reroll completes, shop_jokers will have new cards; we emit from update loop
    BREC.pending_shop_inventory = true
    rec.emit("SHOP_REROLL", {
        state_before = before,
        action       = { reroll_cost = G.GAME and G.GAME.current_round and G.GAME.current_round.reroll_cost },
        resolution   = {},
        state_after  = snap.compact(),
    })
end

function Hooks.on_shop_inventory_after_reroll(reroll_n)
    local slots = enc.shop_inventory()
    local reroll_cost = G.GAME and G.GAME.current_round and G.GAME.current_round.reroll_cost or 5
    rec.emit("SHOP_INVENTORY", {
        state_before = {},
        action       = { reroll_number = reroll_n, reroll_cost = reroll_cost },
        resolution   = { slots = slots },
        state_after  = snap.compact(),
    })
end

function Hooks.on_shop_buy(e)
    if not e then return end
    local c1 = e.config and e.config.ref_table
    if not c1 then return end
    local before = snap.compact()
    BREC.money_source = "SHOP_BUY"
    rec.emit("SHOP_BUY", {
        state_before = before,
        action       = { item = enc.shop_item(c1), item_key = (c1.config and c1.config.center and c1.config.center.key) },
        resolution   = { cost = c1.cost },
        state_after  = snap.compact(),
    })
    -- if buying a playing card, note deck change
    if c1.ability and (c1.ability.set == 'Default' or c1.ability.set == 'Enhanced') then
        rec.emit("DECK_CHANGE", {
            state_before = before,
            action       = {},
            resolution   = {
                cause   = "SHOP_BUY",
                added   = { enc.card(c1) },
                removed = {},
                modified= {},
            },
            state_after  = snap.compact(),
        })
    end
    -- after buy, update joker graph if joker acquired
    if c1.ability and c1.ability.set == 'Joker' then
        rec.emit("JOKER_GRAPH", {
            trigger     = "AFTER_BUY",
            state_before= {},
            action      = {},
            resolution  = { jokers = snap.joker_graph() },
            state_after = {},
        })
    end
end

function Hooks.on_shop_sell(e)
    if not e then return end
    local c1 = e.config and e.config.ref_table
    if not c1 then return end
    local before = snap.compact()
    BREC.money_source = "SHOP_SELL"
    rec.emit("SHOP_SELL", {
        state_before = before,
        action       = { item = enc.joker(c1), item_key = (c1.config and c1.config.center and c1.config.center.key) },
        resolution   = { sell_price = c1.sell_cost },
        state_after  = snap.compact(),
    })
    if c1.ability and c1.ability.set == 'Joker' then
        rec.emit("JOKER_GRAPH", {
            trigger     = "AFTER_SELL",
            state_before= {},
            action      = {},
            resolution  = { jokers = snap.joker_graph() },
            state_after = {},
        })
    end
    if c1.ability and (c1.ability.set == 'Default' or c1.ability.set == 'Enhanced') then
        rec.emit("DECK_CHANGE", {
            state_before = before,
            action       = {},
            resolution   = {
                cause   = "SHOP_SELL",
                added   = {},
                removed = { enc.card(c1) },
                modified= {},
            },
            state_after  = snap.compact(),
        })
    end
end

function Hooks.on_use_card(e)
    if not e then return end
    local c1 = e.config and e.config.ref_table
    if not c1 then return end
    local before = snap.compact()

    local targets = {}
    if G.hand then
        for _, hc in ipairs(G.hand.highlighted or {}) do
            table.insert(targets, enc.card(hc))
        end
    end

    rec.emit("CONSUMABLE_USED", {
        state_before = before,
        action       = {
            item_key = (c1.config and c1.config.center and c1.config.center.key),
            item     = enc.consumable(c1),
            targets  = targets,
        },
        resolution   = {},
        state_after  = snap.compact(),
    })
    -- deck may change; we'll log DECK_CHANGE via the deck diff in update loop
    BREC.pending_deck_diff = true
    rec.emit("CONSUMABLE_SNAPSHOT", {
        state_before = {},
        action       = { trigger = "AFTER_USE" },
        resolution   = { consumables = enc.consumable_list(G.consumeables and G.consumeables.cards) },
        state_after  = {},
    })
end

-- ───────────────────────────────────────────────
-- Booster pack opened
-- ───────────────────────────────────────────────

function Hooks.on_pack_open(pack_card, options, selected_index)
    local option_keys = {}
    for _, c in ipairs(options or {}) do
        local key = (c.config and c.config.center and c.config.center.key) or (c.ability and c.ability.name)
        table.insert(option_keys, key)
    end
    local selected = options and options[selected_index]
    rec.emit("PACK_OPENED", {
        state_before = snap.compact(),
        action       = {
            pack_key = (pack_card and pack_card.config and pack_card.config.center and pack_card.config.center.key),
            options  = option_keys,
            selected_index = selected_index,
            selected = selected and (selected.config and selected.config.center and selected.config.center.key),
        },
        resolution   = {},
        state_after  = snap.compact(),
    })
end

-- ───────────────────────────────────────────────
-- Money ledger (called from ease_dollars wrapper)
-- ───────────────────────────────────────────────

function Hooks.on_money_change(delta)
    if not (G and G.GAME) then return end
    rec.emit("MONEY_CHANGE", {
        state_before = { dollars = G.GAME.dollars },
        action       = { delta = delta, source = BREC.money_source or "UNKNOWN" },
        resolution   = { balance_after = (G.GAME.dollars or 0) + (delta or 0) },
        state_after  = {},
    })
    BREC.money_source = nil
end

-- ───────────────────────────────────────────────
-- RNG tracking
-- ───────────────────────────────────────────────

function Hooks.on_rng_call(seed_val, result)
    rec.emit("RNG_CALL", {
        state_before = {},
        action       = { seed = seed_val, purpose = BREC.rng_purpose or "unknown" },
        resolution   = { result = result, rng_index = BREC.rng_index },
        state_after  = {},
    })
end

return Hooks
