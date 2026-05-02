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

    rec.emit("HAND_LEVELS", {
        trigger     = "RUN_START",
        state_before= {},
        action      = {},
        resolution  = { hands = snap.hand_levels() },
        state_after = {},
    })
end

function Hooks.on_game_over(won)
    local event  = won and "GAME_WIN" or "GAME_OVER"
    local before = snap.compact()
    local res    = {
        ante    = before.ante,
        round   = before.round,
        dollars = before.dollars,
    }
    if won then
        res.stats = snap.win_stats()
    end
    rec.emit(event, {
        state_before = before,
        action       = {},
        resolution   = res,
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

    -- leaving shop: snapshot what was left unbought (the tradeoffs not taken)
    if from_id == 5 then
        local remaining = enc.shop_inventory()
        rec.emit("SHOP_CLOSED", {
            state_before = snap.compact(),
            action       = {},
            resolution   = { items_not_bought = remaining },
            state_after  = {},
        })
    end

    -- entering blind selection: log all available blinds
    if to_id == 7 then  -- BLIND_SELECT
        Hooks.on_blind_select_enter()
    end

    -- entering SELECTING_HAND: blind is now fully initialised, emit ROUND_START
    if to_id == 1 and BREC.pending_round_start then
        BREC.pending_round_start = false
        local blind = G.GAME and G.GAME.blind
        if blind then
            local bkey = (blind.config and blind.config.blind and blind.config.blind.key)
                      or (blind.config and blind.config.center and blind.config.center.key)
            local before = snap.compact()
            rec.emit("ROUND_START", {
                state_before = before,
                action       = { blind_key = bkey },
                resolution   = {
                    blind_name   = blind.name,
                    chips_needed = blind.chips,
                    boss         = blind.boss,
                },
                state_after  = snap.compact(),
            })
            if blind.boss then
                rec.emit("BOSS_BLIND_ACTIVE", {
                    state_before = before,
                    action       = {},
                    resolution   = {
                        key  = bkey,
                        name = blind.name,
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
    end

    -- every time we enter SELECTING_HAND, emit the current hand (initial deal or post-discard redraw)
    if to_id == 1 and G.hand then
        local dealt = {}
        for _, c in ipairs(G.hand.cards or {}) do
            table.insert(dealt, enc.card(c))
        end
        rec.emit("HAND_DEALT", {
            state_before = snap.compact(),
            action       = {},
            resolution   = { cards = dealt },
            state_after  = {},
        })
    end

    -- entering ROUND_EVAL: only a true round win when coming from HAND_PLAYED
    if to_id == 6 then
        BREC.money_source = "BLIND_REWARD"
        if from_id == 2 then  -- 2 = HAND_PLAYED
            Hooks.on_round_won()
        end
    end

    -- entering shop: clear money source, log full inventory
    if to_id == 5 then  -- SHOP
        BREC.money_source = nil
        Hooks.on_shop_enter()
    end

    -- entering NEW_ROUND: log round start
    if to_id == 19 then  -- NEW_ROUND
        Hooks.on_round_start()
    end

    -- GAME_OVER / GAME_WIN are handled by the G.FUNCS.game_over wrapper in init.lua
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

    local small_key = "bl_small"
    local big_key   = "bl_big"
    -- boss key: try several paths Balatro uses across versions
    local rr = G.GAME.round_resets or {}
    local boss_key = G.GAME.boss_blind_on_deck
                  or (rr.blind_states and rr.blind_states.Boss and rr.blind_states.Boss.key)
                  or (rr.blind_choices and rr.blind_choices.Boss and rr.blind_choices.Boss.key)
                  or (G.GAME.boss and G.GAME.boss.key)

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
    -- G.GAME.blind exists here but name/chips/key aren't populated yet.
    -- Set a flag so on_state_change emits ROUND_START once SELECTING_HAND is reached
    -- (by then the blind object is fully initialised).
    BREC.pending_round_start = true
end

function Hooks.on_blind_skipped(e, tags_before_count, blind_before)
    if not (G and G.GAME) then return end
    tags_before_count = tags_before_count or 0
    -- collect tags added by this skip (G.GAME.tags, not G.tags which is nil)
    local new_tags = {}
    if G.GAME.tags then
        for i = tags_before_count + 1, #G.GAME.tags do
            local t = G.GAME.tags[i]
            table.insert(new_tags, t.key or (t.config and t.config.type) or "unknown")
        end
    end
    rec.emit("BLIND_SKIPPED", {
        state_before = snap.compact(),
        action       = { blind_key = blind_before },
        resolution   = { tags_earned = new_tags },
        state_after  = snap.compact(),
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
            hand_levels  = snap.hand_levels(),
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
    -- check for deck changes caused by jokers (Midas Mask, Vampire, Glass Card breaks, etc.)
    BREC.pending_deck_diff = true
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
    -- note gold/rental cards held in hand: their payout fires via ease_dollars shortly after
    local held_effects = {}
    if G.hand then
        for _, c in ipairs(G.hand.cards or {}) do
            local enh = c.ability and c.ability.effect
            if enh == 'Gold Card' then
                table.insert(held_effects, { card = enc.card(c), effect = "gold", dollars = 3 })
            end
            if c.ability and c.ability.rental then
                table.insert(held_effects, { card = enc.card(c), effect = "rental", dollars = -1 })
            end
        end
    end
    rec.emit("ROUND_WON", {
        state_before = before,
        action       = {},
        resolution   = {
            chips_scored  = before.chips_scored,
            chips_needed  = before.chips_needed,
            dollars_after = before.dollars,
            held_effects  = #held_effects > 0 and held_effects or nil,
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

-- Called before orig_use_card: captures pre-use state and emits purchase events.
function Hooks.on_before_use_card(e)
    if not e then return end
    local c1 = e.config and e.config.ref_table
    if not c1 then return end
    local item_key = c1.config and c1.config.center and c1.config.center.key
    local before   = snap.compact()

    -- Booster pack clicked from shop: fires use_card instead of buy_from_shop
    if c1.ability and (c1.ability.set == 'Booster' or c1.ability.set == 'Voucher') then
        BREC.money_source  = "SHOP_BUY"
        BREC.last_pack_key = c1.ability.set == 'Booster' and item_key or nil
        rec.emit("SHOP_BUY", {
            state_before = before,
            action       = { item_key = item_key, item = enc.shop_item(c1) },
            resolution   = { cost = c1.cost },
            state_after  = {},  -- filled in on_after_use_card
        })
        BREC._pending_use_type = c1.ability.set  -- remember for after hook
        return
    end

    -- Card picked from inside an open booster pack (states 8-18 are pack-selection states)
    if G.STATE and G.STATE >= 8 and G.STATE <= 18 then
        -- G.pack_cards is a CardArea object; actual card list is in .cards
        local options = {}
        for _, pc in ipairs((G.pack_cards and G.pack_cards.cards) or {}) do
            local k = pc.config and pc.config.center and pc.config.center.key
            table.insert(options, k or "unknown")
        end
        BREC._pending_use_type = 'PackPick'
        BREC._pending_pack_pick = {
            pack_key = BREC.last_pack_key,
            selected = item_key,
            set      = c1.ability and c1.ability.set,
            options  = options,
            before   = before,
        }
        return
    end

    -- Regular consumable (tarot, planet, spectral): capture before-state + targets now
    local targets = {}
    if G.hand then
        for _, hc in ipairs(G.hand.highlighted or {}) do
            table.insert(targets, enc.card(hc))
        end
    end
    BREC._pending_use_type = 'Consumable'
    BREC._pending_consumable = {
        item_key = item_key,
        item     = enc.consumable(c1),
        targets  = targets,
        before   = before,
    }
end

-- Called after orig_use_card: emits events that need post-effect state.
function Hooks.on_after_use_card(e)
    local ut = BREC._pending_use_type
    BREC._pending_use_type = nil

    if ut == 'Booster' or ut == 'Voucher' then
        -- nothing extra needed; SHOP_BUY already emitted; pack open handled on next use_card
        return
    end

    if ut == 'PackPick' then
        local p = BREC._pending_pack_pick or {}
        BREC._pending_pack_pick = nil
        local ignored = {}
        for _, k in ipairs(p.options or {}) do
            if k ~= p.selected then table.insert(ignored, k) end
        end
        rec.emit("PACK_OPENED", {
            state_before = p.before,
            action       = {
                pack_key = p.pack_key,
                options  = p.options,
                selected = p.selected,
                ignored  = ignored,
            },
            resolution   = {},
            state_after  = snap.compact(),
        })
        if p.set == 'Joker' then
            rec.emit("JOKER_GRAPH", {
                trigger     = "AFTER_PACK",
                state_before= {},
                action      = {},
                resolution  = { jokers = snap.joker_graph() },
                state_after = {},
            })
        end
        return
    end

    if ut == 'Consumable' then
        local p = BREC._pending_consumable or {}
        BREC._pending_consumable = nil
        rec.emit("CONSUMABLE_USED", {
            state_before = p.before,
            action       = { item_key = p.item_key, item = p.item, targets = p.targets },
            resolution   = {},
            state_after  = snap.compact(),
        })
        BREC.pending_deck_diff = true
        -- snapshot AFTER effect so Emperor's added tarots, Wheel of Fortune edition, etc. are visible
        rec.emit("CONSUMABLE_SNAPSHOT", {
            state_before = {},
            action       = { trigger = "AFTER_USE" },
            resolution   = { consumables = enc.consumable_list(G.consumeables and G.consumeables.cards) },
            state_after  = {},
        })
        -- JOKER_GRAPH captures any edition changes (Wheel of Fortune, etc.)
        rec.emit("JOKER_GRAPH", {
            trigger     = "AFTER_CONSUMABLE",
            state_before= {},
            action      = { item_key = p.item_key },
            resolution  = { jokers = snap.joker_graph() },
            state_after = {},
        })
        -- Planet cards level up poker hands — emit updated table
        if p.item and p.item.set == 'Planet' then
            rec.emit("HAND_LEVELS", {
                trigger     = "PLANET_USED",
                state_before= {},
                action      = { item_key = p.item_key },
                resolution  = { hands = snap.hand_levels() },
                state_after = {},
            })
        end
        return
    end
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
    -- Keep BLIND_REWARD across multiple calls (blind reward + interest fire separately);
    -- all other sources are one-shot and cleared immediately
    if BREC.money_source ~= "BLIND_REWARD" then
        BREC.money_source = nil
    end
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
