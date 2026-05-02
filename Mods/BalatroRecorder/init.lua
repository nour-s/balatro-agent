-- BalatroRecorder init.lua
-- Called by Lovely patches:
--   brec_init.startup() — after G:start_up()
--   brec_init.update()  — every frame after G:update(dt)

local BrecInit = {}

-- Global state shared across all modules
BREC = {
    active              = false,
    scoring_active      = false,
    scoring_chain       = {},
    scoring_base        = {},
    state_before_hand   = nil,
    state_before_discard= nil,
    play_cards          = nil,
    discard_cards       = nil,
    money_source        = nil,
    rng_purpose         = nil,
    rng_index           = 0,
    prev_state          = nil,
    prev_dollars        = nil,
    shop_reroll_count   = 0,
    pending_shop_inventory = false,
    pending_deck_diff   = false,
    deck_snapshot       = nil,  -- last known deck card list
    last_pack_key          = nil,
    pending_round_start    = false,
    _pending_use_type      = nil,
    _pending_consumable    = nil,
    _pending_pack_pick     = nil,
    _state_frame           = 0,
}

local function brec_error(msg)
    print("[BalatroRecorder ERROR] " .. tostring(msg))
end

local function safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then brec_error(err) end
end

-- ───────────────────────────────────────────────
-- Startup: wrap game functions
-- ───────────────────────────────────────────────

function BrecInit.startup()
    local h = require("hooks")

    -- ── play_cards_from_highlighted ──
    local orig_play = G.FUNCS.play_cards_from_highlighted
    G.FUNCS.play_cards_from_highlighted = function(e)
        safe(h.on_before_play)
        orig_play(e)
    end

    -- ── discard_cards_from_highlighted ──
    local orig_discard = G.FUNCS.discard_cards_from_highlighted
    G.FUNCS.discard_cards_from_highlighted = function(e, hook)
        safe(h.on_before_discard)
        orig_discard(e, hook)
        safe(h.on_after_discard)
    end

    -- ── evaluate_play (scoring loop wrapper) ──
    local orig_eval_play = G.FUNCS.evaluate_play
    G.FUNCS.evaluate_play = function(e)
        BREC.scoring_chain = {}
        BREC.scoring_base  = { hand_type = nil, base_chips = 0, base_mult = 0 }
        orig_eval_play(e)
        -- capture hand info immediately after scoring; current_hand is cleared later
        if G.GAME and G.GAME.current_round then
            local ch = G.GAME.current_round.current_hand or {}
            BREC.last_hand_info = {
                hand_type = ch.handname or "",
                chips     = ch.chips or 0,
                mult      = ch.mult  or 0,
            }
        end
    end

    -- ── buy_from_shop ──
    local orig_buy = G.FUNCS.buy_from_shop
    G.FUNCS.buy_from_shop = function(e)
        safe(h.on_shop_buy, e)
        orig_buy(e)
    end

    -- ── sell_card ──
    local orig_sell = G.FUNCS.sell_card
    G.FUNCS.sell_card = function(e)
        safe(h.on_shop_sell, e)
        orig_sell(e)
    end

    -- ── use_card ──
    local orig_use = G.FUNCS.use_card
    G.FUNCS.use_card = function(e, mute, nosave)
        safe(h.on_before_use_card, e)
        orig_use(e, mute, nosave)
        safe(h.on_after_use_card, e)
    end

    -- ── select_blind ──
    local orig_sel_blind = G.FUNCS.select_blind
    G.FUNCS.select_blind = function(e)
        orig_sel_blind(e)
        safe(h.on_blind_selected, e)
    end

    -- ── skip_blind ──
    local orig_skip_blind = G.FUNCS.skip_blind
    G.FUNCS.skip_blind = function(e)
        -- capture BEFORE orig runs: blind_on_deck advances after skip, tags not yet added
        local blind_before = G.GAME and G.GAME.blind_on_deck
        local tags_before  = G.GAME and G.GAME.tags and #G.GAME.tags or 0
        orig_skip_blind(e)
        safe(h.on_blind_skipped, e, tags_before, blind_before)
    end

    -- ── reroll_boss ──
    local orig_reroll_boss = G.FUNCS.reroll_boss
    G.FUNCS.reroll_boss = function(e)
        safe(h.on_boss_rerolled, e)
        orig_reroll_boss(e)
    end

    -- ── reroll_shop ──
    local orig_reroll_shop = G.FUNCS.reroll_shop
    G.FUNCS.reroll_shop = function(e)
        BREC.shop_reroll_count = BREC.shop_reroll_count + 1
        safe(h.on_shop_reroll)
        orig_reroll_shop(e)
    end

    -- ── start_run ──
    local orig_start_run = G.FUNCS.start_run
    G.FUNCS.start_run = function(e, args)
        orig_start_run(e, args)
        -- on_run_start is called from update loop when state transitions to NEW_ROUND/SELECTING_HAND for the first time
        BREC.run_pending_init = true
    end

    -- ── game_over (win/loss) ──
    -- G.FUNCS.game_over is called with won=true on a win, won=false on a loss
    if G.FUNCS.game_over then
        local orig_game_over = G.FUNCS.game_over
        G.FUNCS.game_over = function(won, ...)
            if BREC.active then
                safe(h.on_game_over, won)
                BREC.active = false
            end
            orig_game_over(won, ...)
        end
    end

    -- ── ease_dollars (money tracking) ──
    local orig_ease_dollars = ease_dollars
    ease_dollars = function(mod, instant)
        safe(h.on_money_change, mod)
        orig_ease_dollars(mod, instant)
    end

    -- ── pseudorandom (RNG tracking) ──
    local orig_pseudorandom = pseudorandom
    pseudorandom = function(seed, min, max)
        local result = orig_pseudorandom(seed, min, max)
        if BREC.active then
            BREC.rng_index = BREC.rng_index + 1
            safe(h.on_rng_call, seed, result)
        end
        return result
    end

    -- ── eval_card (scoring chain capture) ──
    -- We wrap the global function to intercept joker evaluations during scoring
    local orig_eval_card = eval_card
    eval_card = function(card, context)
        local result = orig_eval_card(card, context)

        if BREC.scoring_active and context and
           (context.cardarea == G.jokers or context.joker_main) and
           G.jokers then
            -- capture the contribution
            -- NOTE: we can't easily get chips/mult before/after here since those are
            -- local vars inside evaluate_play.  We record what eval_card returned.
            if result and result.jokers and next(result.jokers) then
                local key = "unknown"
                if card.config and card.config.center then
                    key = card.config.center.key or key
                end
                local pos = 0
                for i, j in ipairs(G.jokers.cards) do
                    if j == card then pos = i - 1; break end
                end
                local step = { source = key, pos = pos }
                local jk = result.jokers
                if jk.mult_mod  then step.mult_delta  = jk.mult_mod  end
                if jk.chip_mod  then step.chips_delta = jk.chip_mod  end
                if jk.Xmult_mod then step.xmult       = jk.Xmult_mod end
                if step.mult_delta or step.chips_delta or step.xmult then
                    table.insert(BREC.scoring_chain, step)
                end
            end
        end

        -- capture held-in-hand card effects (Steel x1.5, Lucky mult/dollars, etc.)
        if BREC.scoring_active and context and context.cardarea == G.hand and result then
            local hres = result.hand
            if hres and next(hres) then
                local base = card.base or {}
                local enh  = card.ability and card.ability.effect
                local label = (base.value or "?") .. (base.suit or "?")
                if enh and enh ~= '' and enh ~= 'Base' then
                    label = label .. "[" .. enh .. "]"
                end
                local step = { source = "held_" .. label, held = true }
                if hres.Xmult_mod  then step.xmult       = hres.Xmult_mod  end
                if hres.mult_mod   then step.mult_delta   = hres.mult_mod   end
                if hres.chip_mod   then step.chips_delta  = hres.chip_mod   end
                if hres.dollars    then step.dollars      = hres.dollars    end
                if step.xmult or step.mult_delta or step.chips_delta or step.dollars then
                    table.insert(BREC.scoring_chain, step)
                end
            end
        end

        -- capture base hand chips/mult from first scoring call
        if BREC.scoring_active and context and context.cardarea == G.play then
            if BREC.scoring_base and not BREC.scoring_base.captured then
                BREC.scoring_base.captured = true
            end
        end

        return result
    end

    print("[BalatroRecorder] All hooks installed.")
end

-- ───────────────────────────────────────────────
-- Frame update loop
-- ───────────────────────────────────────────────

-- Returns a flat deck fingerprint for diffing
local function deck_fingerprint(cards)
    local fp = {}
    for _, c in ipairs(cards or {}) do
        local base = c.base or {}
        table.insert(fp, (base.suit or "?") .. "_" .. (base.value or "?"))
    end
    table.sort(fp)
    return table.concat(fp, "|")
end

local last_hand_play_state = nil  -- detect HAND_PLAYED→DRAW_TO_HAND transition
local shop_inventory_frame_wait = 0  -- frames to wait after reroll before reading new inventory

function BrecInit.update()
    -- Poll bridge commands before the G.GAME guard so start_run works from main menu.
    if G then
        local bridge = require("bridge")
        local cmd = bridge.read_command()
        if cmd then safe(bridge.execute, cmd) end
    end

    if not (G and G.STATE and G.GAME) then return end

    local h = require("hooks")

    -- ── Run init: activate as soon as we hit BLIND_SELECT or later ──
    if BREC.run_pending_init and
       (G.STATE == 7 or G.STATE == 19 or G.STATE == G.STATES.SELECTING_HAND) then
        BREC.run_pending_init = false
        BREC.active           = true
        BREC.rng_index        = 0
        BREC.shop_reroll_count= 0
        -- capture initial deck snapshot for future diffs
        if G.deck then
            BREC.deck_snapshot = deck_fingerprint(G.deck.cards)
        end
        safe(h.on_run_start)
    end

    -- ── Fallback activation for resumed/continued runs ──
    -- If BREC was never activated via start_run (e.g. game loaded via continue),
    -- activate automatically when we detect an in-progress run.
    if not BREC.active and G.GAME and G.GAME.round and G.GAME.round > 0 then
        BREC.active           = true
        BREC.rng_index        = 0
        BREC.shop_reroll_count= 0
        if G.deck then
            BREC.deck_snapshot = deck_fingerprint(G.deck.cards)
        end
        print("[BalatroRecorder] Activated via resumed-run fallback (round=" .. tostring(G.GAME.round) .. ")")
    end

    -- ── Action bridge: state write (always, even before run starts) ──────────
    local bridge = require("bridge")
    BREC._state_frame = (BREC._state_frame or 0) + 1
    if BREC._state_frame >= 30 then
        BREC._state_frame = 0
        safe(bridge.write_state)
    end

    if not BREC.active then return end

    -- ── State machine: detect transitions ──
    local cur_state = G.STATE
    if cur_state ~= BREC.prev_state then
        safe(h.on_state_change, BREC.prev_state, cur_state)
        BREC.prev_state = cur_state

        -- Scoring done: HAND_PLAYED → DRAW_TO_HAND (mid-round) or → NEW_ROUND / GAME_OVER (last hand)
        local scoring_done = last_hand_play_state == G.STATES.HAND_PLAYED and
            (cur_state == G.STATES.DRAW_TO_HAND or cur_state == 19 or cur_state == 4)
        if scoring_done and BREC.state_before_hand then
            local info        = BREC.last_hand_info or {}
            local chips_before = BREC.state_before_hand.chips_scored or 0
            local chips_after  = G.GAME.chips or 0
            safe(h.on_hand_result,
                info.hand_type or "",
                info.chips     or 0,
                info.mult      or 0,
                chips_after - chips_before)
        end

        last_hand_play_state = cur_state
    end

    -- ── Pending shop inventory (after reroll, wait a few frames) ──
    -- Set frame wait outside the state-change block so it fires even without a transition
    if BREC.pending_shop_inventory then
        shop_inventory_frame_wait   = 5
        BREC.pending_shop_inventory = false
    end
    if shop_inventory_frame_wait > 0 then
        shop_inventory_frame_wait = shop_inventory_frame_wait - 1
        if shop_inventory_frame_wait == 0 then
            safe(h.on_shop_inventory_after_reroll, BREC.shop_reroll_count)
        end
    end

    -- ── Deck diff: detect changes after consumable use ──
    if BREC.pending_deck_diff and G.deck then
        BREC.pending_deck_diff = false
        local new_fp = deck_fingerprint(G.deck.cards)
        if new_fp ~= BREC.deck_snapshot then
            local enc = require("encoder")
            -- emit deck change (simplified: we know it changed but re-snapshot)
            local h_rec = require("recorder")
            h_rec.emit("DECK_CHANGE", {
                state_before = {},
                action       = {},
                resolution   = {
                    cause         = "CONSUMABLE_USED",
                    deck_snapshot = enc.deck(G.deck.cards),
                    deck_size     = #G.deck.cards,
                },
                state_after  = require("snapshot").compact(),
            })
            BREC.deck_snapshot = new_fp
        end
    end

    -- ── Money change detection (belt-and-suspenders) ──
    -- primary tracking is via ease_dollars wrapper; this catches any missed changes
    local cur_dollars = G.GAME.dollars or 0
    if BREC.prev_dollars ~= nil and cur_dollars ~= BREC.prev_dollars then
        -- only emit if ease_dollars wrapper didn't already emit (money_source would be nil there)
        -- we skip here to avoid duplicates since ease_dollars handles it
    end
    BREC.prev_dollars = cur_dollars

    -- GAME_OVER / GAME_WIN deactivation handled by G.FUNCS.game_over wrapper

end

return BrecInit
