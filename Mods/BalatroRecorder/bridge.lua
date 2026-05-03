-- BalatroRecorder bridge.lua
-- File-based IPC for Claude <-> game bidirectional control.
--   Out: write_state() dumps compact game state to ~/balatro-logs/state.json every ~30 frames
--   In:  read_command() polls ~/balatro-logs/command.json; execute(cmd) dispatches it

local Bridge = {}

local cfg          = require("brec_config")
local STATE_PATH   = cfg.LOG_DIR .. "/state.json"
local COMMAND_PATH = cfg.LOG_DIR .. "/command.json"

-- Resolve G.STATE integer to a human-readable name
local function state_name()
    if not (G and G.STATES and G.STATE) then return "UNKNOWN" end
    for k, v in pairs(G.STATES) do
        if v == G.STATE then return k end
    end
    return tostring(G.STATE)
end

-- Encode hand cards with 1-based idx for command use.
-- Respects face-down state: if the card is facing away from the player
-- (blind abilities like The House flip cards), emit only idx and facing="down"
-- so the agent sees exactly what a human would see.
local function encode_hand()
    local enc = require("encoder")
    local out = {}
    for i, c in ipairs(G.hand and G.hand.cards or {}) do
        if c.facing == 'back' then
            table.insert(out, { idx = i, facing = "down" })
        else
            local t = enc.card(c)
            t.idx = i
            table.insert(out, t)
        end
    end
    return out
end

-- Encode one shop CardArea into {slot, key, cost, ...} list
local function encode_shop_area(area)
    local enc = require("encoder")
    local out = {}
    for i, c in ipairs(area and area.cards or {}) do
        local item = enc.shop_item(c)
        if item then
            item.slot = i
            table.insert(out, item)
        end
    end
    return out
end

-- ── write_state ──────────────────────────────────────────────────────────────
-- Writes compact game state to STATE_PATH atomically (tmp → rename).
function Bridge.write_state()
    if not G then return end
    -- During SPLASH/loading G.GAME is nil — write a minimal state so the agent
    -- knows the game is alive and just loading, rather than seeing a stale file.
    if not G.GAME then
        local json = require("dkjson")
        local tmp = STATE_PATH .. ".tmp"
        local f = io.open(tmp, "w")
        if not f then return end
        f:write(json.encode({ state = state_name() }))
        f:close()
        os.rename(tmp, STATE_PATH)
        return
    end
    local json = require("dkjson")
    local enc  = require("encoder")
    local snap = require("snapshot")
    local s    = snap.compact()

    local data = {
        state         = state_name(),
        ante          = s.ante,
        round         = s.round,
        hands_left    = s.hands_left,
        discards_left = s.discards_left,
        chips_scored  = s.chips_scored,
        chips_needed  = s.chips_needed,
        dollars       = s.dollars,
        hand          = encode_hand(),
        jokers        = enc.joker_list(G.jokers and G.jokers.cards or {}, "Joker"),
        vouchers      = enc.joker_list(G.jokers and G.jokers.cards or {}, "Voucher"),
        consumables   = enc.consumable_list(G.consumeables and G.consumeables.cards or {}),
        shop = {
            jokers   = encode_shop_area(G.shop_jokers),
            vouchers = encode_shop_area(G.shop_vouchers),
            boosters = encode_shop_area(G.shop_booster),
        },
    }

    local json_str = json.encode(data)
    local tmp = STATE_PATH .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return end
    f:write(json_str)
    f:close()
    os.rename(tmp, STATE_PATH)
end

-- ── read_command ─────────────────────────────────────────────────────────────
-- Returns parsed command table from COMMAND_PATH and deletes the file, or nil.
function Bridge.read_command()
    local f = io.open(COMMAND_PATH, "r")
    if not f then return nil end
    local contents = f:read("*a")
    f:close()
    os.remove(COMMAND_PATH)
    if not (contents and contents ~= "") then return nil end
    local json = require("dkjson")
    local ok, cmd = pcall(json.decode, contents)
    if ok and type(cmd) == "table" then return cmd end
    return nil
end

-- ── highlight helpers ─────────────────────────────────────────────────────────

local function highlight_hand_cards(indices)
    G.hand.highlighted = {}
    for _, c in ipairs(G.hand.cards or {}) do
        c.highlighted = false
    end
    for _, idx in ipairs(indices or {}) do
        local c = G.hand.cards[idx]
        if c then
            c.highlighted = true
            table.insert(G.hand.highlighted, c)
        end
    end
end

-- ── execute ───────────────────────────────────────────────────────────────────
-- Dispatches a parsed command table to the appropriate G.FUNCS call.
function Bridge.execute(cmd)
    if not (cmd and cmd.action) then return end
    local action = cmd.action

    if action == "play" then
        if G.STATE == G.STATES.SELECTING_HAND then
            highlight_hand_cards(cmd.hand_indices or {})
            G.FUNCS.play_cards_from_highlighted({config = {}})
        end

    elseif action == "discard" then
        if G.STATE == G.STATES.SELECTING_HAND then
            highlight_hand_cards(cmd.hand_indices or {})
            G.FUNCS.discard_cards_from_highlighted({config = {}})
        end

    elseif action == "select_blind" then
        if G.STATE == 7 then  -- BLIND_SELECT
            -- blind_choices stores string keys (e.g. 'bl_small'); look up the actual
            -- blind data table in G.P_BLINDS so set_blind() and discover_card() get
            -- a table, not a string (string causes crash in discover_card).
            local rr = G.GAME.round_resets or {}
            local choices = rr.blind_choices or {}
            local deck = G.GAME.blind_on_deck or ""
            local key = choices[deck] or choices.Boss
            local ref = G.P_BLINDS and G.P_BLINDS[key]
            G.FUNCS.select_blind({config = {ref_table = ref}})
        end

    elseif action == "skip_blind" then
        if G.STATE == 7 then
            local rr = G.GAME.round_resets or {}
            local choices = rr.blind_choices or {}
            local deck = G.GAME.blind_on_deck or ""
            local key = choices[deck] or choices.Boss
            local ref = G.P_BLINDS and G.P_BLINDS[key]
            G.FUNCS.skip_blind({config = {ref_table = ref}})
        end

    elseif action == "cash_out" then
        if G.STATE == G.STATES.ROUND_EVAL then
            G.FUNCS.cash_out({config = {}})
        end

    elseif action == "reroll_boss" then
        G.FUNCS.reroll_boss({config = {}})

    elseif action == "reroll_shop" then
        if G.STATE == G.STATES.SHOP then
            G.FUNCS.reroll_shop({config = {}})
        end

    elseif action == "buy" then
        local area_map = {
            joker   = G.shop_jokers,
            voucher = G.shop_vouchers,
            booster = G.shop_booster,
        }
        local area = area_map[cmd.area or "joker"]
        local card = area and area.cards and area.cards[cmd.slot or 1]
        if card then
            G.FUNCS.buy_from_shop({config = {ref_table = card}})
        end

    elseif action == "sell" then
        -- joker_slot is 1-based index into the jokers[] array in state.json,
        -- which contains only "Joker"-set items. We must find the Nth joker
        -- within G.jokers.cards (which also contains vouchers).
        local target_slot = cmd.joker_slot or 1
        local joker_count = 0
        local card = nil
        for _, j in ipairs(G.jokers and G.jokers.cards or {}) do
            if (j.ability or {}).set == "Joker" then
                joker_count = joker_count + 1
                if joker_count == target_slot then
                    card = j
                    break
                end
            end
        end
        if card then
            G.FUNCS.sell_card({config = {ref_table = card}})
        end

    elseif action == "next_round" then
        if G.STATE == G.STATES.SHOP then
            -- try the standard shop exit; Balatro versions differ on the exact call
            if G.FUNCS.toggle_shop then
                G.FUNCS.toggle_shop({config = {}})
            elseif G.FUNCS.end_round then
                G.FUNCS.end_round({config = {}})
            end
        end

    elseif action == "start_run" then
        -- Route through G.FUNCS.start_run so G:delete_run() fires and
        -- G.MAIN_MENU_UI:remove() is called — without this the main menu
        -- overlay (locked card hint) persists on top of the entire run.
        if cmd.continue then
            -- Continue saved run: load save file the same way can_continue does.
            if not G.SAVED_GAME then
                G.SAVED_GAME = get_compressed(G.SETTINGS.profile .. '/' .. 'save.jkr')
                if G.SAVED_GAME ~= nil then G.SAVED_GAME = STR_UNPACK(G.SAVED_GAME) end
            end
            if G.SAVED_GAME then
                pcall(G.FUNCS.start_run, nil, {savetext = G.SAVED_GAME})
            end
        else
            -- New run with optional deck/stake/seed.
            local deck_key = cmd.deck or "b_red"
            pcall(G.FUNCS.start_run, nil, {
                stake     = cmd.stake or 1,
                seed      = cmd.seed or nil,
                challenge = nil,
                deck      = G.P_CENTERS and G.P_CENTERS[deck_key] or nil,
            })
        end

    elseif action == "use_consumable" then
        local card = G.consumeables and G.consumeables.cards and
                     G.consumeables.cards[cmd.consumable_slot or 1]
        if card then
            if cmd.hand_indices and #cmd.hand_indices > 0 then
                highlight_hand_cards(cmd.hand_indices)
            end
            G.FUNCS.use_card({config = {ref_table = card}})
        end
    end
end

return Bridge
