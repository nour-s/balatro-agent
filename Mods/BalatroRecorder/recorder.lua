-- Recorder: manages log file handles and emits structured events.

local json = require("dkjson")
local cfg  = require("brec_config")

local Recorder = {
    seq        = 0,
    txt_handle = nil,
    json_handle= nil,
    run_seed   = nil,
}

local STATE_NAMES = {
    [1]  = "SELECTING_HAND",
    [2]  = "HAND_PLAYED",
    [3]  = "DRAW_TO_HAND",
    [4]  = "GAME_OVER",
    [5]  = "SHOP",
    [6]  = "PLAY_TAROT",
    [7]  = "BLIND_SELECT",
    [8]  = "ROUND_EVAL",
    [9]  = "TAROT_PACK",
    [10] = "PLANET_PACK",
    [11] = "MENU",
    [12] = "TUTORIAL",
    [13] = "SPLASH",
    [14] = "SANDBOX",
    [15] = "SPECTRAL_PACK",
    [16] = "DEMO_CTA",
    [17] = "STANDARD_PACK",
    [18] = "BUFFOON_PACK",
    [19] = "NEW_ROUND",
}

function Recorder.state_name(id)
    return STATE_NAMES[id] or ("STATE_" .. tostring(id))
end

local function ensure_dir(path)
    os.execute('mkdir -p "' .. path .. '"')
end

-- Returns the path (without extension) of the most recent in-progress file
-- for this seed, or nil if none exists / last run was completed.
local function find_continuation(seed)
    local pattern = cfg.LOG_DIR .. "/*_" .. seed .. ".jsonl"
    local handle  = io.popen('ls "' .. cfg.LOG_DIR .. '"/ 2>/dev/null | grep "_' .. seed .. '\\.jsonl$" | sort | tail -1')
    if not handle then return nil end
    local filename = handle:read("*l")
    handle:close()
    if not filename or filename == "" then return nil end

    local full = cfg.LOG_DIR .. "/" .. filename

    -- Verify the run wasn't completed (no GAME_OVER or GAME_WIN in last 10 lines)
    local tail = io.popen('tail -10 "' .. full .. '" 2>/dev/null')
    if not tail then return nil end
    local content = tail:read("*a")
    tail:close()
    if content:find('"GAME_OVER"') or content:find('"GAME_WIN"') then
        return nil  -- run already completed, don't append
    end

    return full:gsub("%.jsonl$", "")
end

function Recorder.open_run(seed, is_fresh)
    ensure_dir(cfg.LOG_DIR)
    Recorder.run_seed = seed
    Recorder.seq      = 0

    local base        = nil
    local appending   = false

    if not is_fresh then
        base = find_continuation(seed)
        if base then appending = true end
    end

    if not base then
        local ts = os.date("%Y%m%d_%H%M%S")
        base = cfg.LOG_DIR .. "/" .. ts .. "_" .. seed
    end

    local mode = appending and "a" or "w"
    Recorder.json_handle = io.open(base .. ".jsonl", mode)
    Recorder.txt_handle  = io.open(base .. ".txt",   mode)

    if Recorder.txt_handle then
        local h = Recorder.txt_handle
        if appending then
            h:write("\n" .. string.rep("─", 44) .. "\n")
            h:write("── RESUMED: " .. os.date("%Y-%m-%d %H:%M:%S") .. " ──\n")
            h:write(string.rep("─", 44) .. "\n\n")
        else
            h:write("=== BALATRO RUN RECORDER ===\n")
            h:write("Seed:  " .. tostring(seed) .. "\n")
            h:write("Time:  " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
            h:write(string.rep("=", 40) .. "\n\n")
        end
        h:flush()
    end
end

function Recorder.close_run()
    if Recorder.txt_handle  then Recorder.txt_handle:close();  Recorder.txt_handle  = nil end
    if Recorder.json_handle then Recorder.json_handle:close(); Recorder.json_handle = nil end
    Recorder.run_seed = nil
end

-- ───────────────────────────────────────────────
-- Human-readable .txt formatting
-- ───────────────────────────────────────────────

local SUIT_SYM = { Hearts="♥", Diamonds="♦", Clubs="♣", Spades="♠" }
local VAL_ABR  = {
    Ace="A", ["2"]="2", ["3"]="3", ["4"]="4", ["5"]="5",
    ["6"]="6", ["7"]="7", ["8"]="8", ["9"]="9",
    ["10"]="10", Jack="J", Queen="Q", King="K",
}

local function num(n)
    if type(n) ~= "number" then return tostring(n or "?") end
    local s = tostring(math.floor(n))
    return s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

local function cstr(c)
    if type(c) ~= "table" then return "?" end
    local v = VAL_ABR[c.value] or (c.value and tostring(c.value):sub(1,2)) or "?"
    local s = SUIT_SYM[c.suit] or (c.suit and c.suit:sub(1,1)) or "?"
    return v .. s
end

local function clist(cards)
    if type(cards) ~= "table" or #cards == 0 then return "" end
    local out = {}
    for _, c in ipairs(cards) do table.insert(out, cstr(c)) end
    return table.concat(out, " ")
end

local function kname(key)
    if type(key) ~= "string" then return "?" end
    -- strip c_, j_, v_, p_, b_, e_ prefixes
    local name = key:gsub("^[cjvpbe]_", "")
    name = name:gsub("_", " ")
    -- title-case
    return name:gsub("(%a)([%w]*)", function(first, rest)
        return first:upper() .. rest:lower()
    end)
end

-- Dispatch table: false = suppress, function = formatter
local TXT = {}

local SUPPRESS = {
    "STATE_CHANGE", "HAND_DEALT", "ROUND_RESOURCES", "CONSUMABLE_SNAPSHOT",
    "DECK_SNAPSHOT", "SHOP_CLOSED", "JOKER_GRAPH", "HAND_LEVELS", "DECK_CHANGE",
    "BLIND_OPTIONS", "BOSS_REROLL", "MONEY_CHANGE", "RUN_START",
}
for _, e in ipairs(SUPPRESS) do TXT[e] = false end

TXT.ROUND_START = function(d)
    local a   = d.action or {}
    local res = d.resolution or {}
    local sb  = d.state_before or {}
    local ante  = sb.ante or "?"
    local round = sb.round or "?"
    local bname = res.blind_name or "?"
    local chips = res.chips_needed
    local btype = res.boss and "boss" or
                  (a.blind_key == "bl_small" and "small" or "big")
    local chips_str = chips and num(chips) or "?"
    return string.format("\n── Ante %s, Round %s ── %s (%s, %s chips needed) ──",
        ante, round, bname, btype, chips_str)
end

TXT.BOSS_BLIND_ACTIVE = function(d)
    local res = d.resolution or {}
    return "  ⚡ Boss: " .. (res.name or "?")
end

TXT.BLIND_SKIPPED = function(d)
    local res  = d.resolution or {}
    local tags = {}
    for _, t in ipairs(res.tags_earned or {}) do
        table.insert(tags, kname(t))
    end
    local tag_str = #tags > 0 and ("  [tags: " .. table.concat(tags, ", ") .. "]") or ""
    return "  Skipped blind" .. tag_str
end

TXT.HAND_PLAYED = function(d)
    local cards = (d.action or {}).cards or {}
    local s = clist(cards)
    return s ~= "" and ("  ► " .. s) or nil
end

TXT.HAND_RESOLUTION = function(d)
    local res = d.resolution or {}
    local sa  = d.state_after  or {}
    local sb  = d.state_before or {}
    local hand_type  = res.hand_type or "?"
    local score      = res.final_score or 0
    local total      = sa.chips_scored or 0
    local needed     = sb.chips_needed or 0
    local won        = needed > 0 and total >= needed
    return string.format("    → %s  %s pts  (%s / %s)%s",
        hand_type, num(score), num(total), num(needed),
        won and " ✓" or "")
end

TXT.CARDS_DISCARDED = function(d)
    local cards = (d.action or {}).cards or {}
    local s = clist(cards)
    return s ~= "" and ("  Discarded: " .. s) or nil
end

TXT.SHOP_INVENTORY = function(d)
    local a  = d.action or {}
    if (a.reroll_number or 0) > 0 then return nil end
    local sb = d.state_before or {}
    return string.format("\n── Shop ($%s) ──", tostring(sb.dollars or "?"))
end

TXT.SHOP_BUY = function(d)
    local a    = d.action or {}
    local item = type(a.item) == "table" and a.item or {}
    local name = item.name or kname(a.item_key or "?")
    local cost = (d.resolution or {}).cost or "?"
    return string.format("  Bought: %s  -$%s", name, cost)
end

TXT.SHOP_SELL = function(d)
    local a     = d.action or {}
    local item  = type(a.item) == "table" and a.item or {}
    local name  = item.name or kname(a.item_key or "?")
    local price = (d.resolution or {}).sell_price or "?"
    return string.format("  Sold: %s  +$%s", name, price)
end

TXT.SHOP_REROLL = function(d)
    local cost = (d.action or {}).reroll_cost or "?"
    return string.format("  Rerolled  -$%s", cost)
end

TXT.PACK_OPENED = function(d)
    local a   = d.action or {}
    local key = a.pack_key or ""
    -- p_arcana_normal_2 → "Arcana Pack", p_buffoon_mega_1 → "Mega Buffoon Pack"
    local pack_type = key:match("^p_(%a+)") or "pack"
    local is_mega   = key:find("_mega_") and true or false
    local pack_name = pack_type:sub(1,1):upper() .. pack_type:sub(2) .. " Pack"
    if is_mega then pack_name = "Mega " .. pack_name end
    local took = a.selected and kname(a.selected) or "nothing"
    return string.format("  Pack: %s  → %s", pack_name, took)
end

TXT.CONSUMABLE_USED = function(d)
    local a    = d.action or {}
    local item = type(a.item) == "table" and a.item or {}
    local name = item.name or kname(a.item_key or "?")
    local tgts = clist(a.targets or {})
    return "  Used: " .. name .. (tgts ~= "" and ("  on [" .. tgts .. "]") or "")
end

TXT.GAME_OVER = function(d)
    local res = d.resolution or {}
    local sb  = d.state_before or {}
    return string.format("\n✗ GAME OVER — Ante %s, Round %s — $%s",
        res.ante or sb.ante or "?",
        res.round or sb.round or "?",
        sb.dollars or "?")
end

TXT.GAME_WIN = function(d)
    local res = d.resolution or {}
    return string.format("\n✓ WIN — Ante %s, Round %s — $%s",
        res.ante or "?", res.round or "?", res.dollars or "?")
end

local function txt_summary(event_key, data)
    local fmt = TXT[event_key]
    if fmt == false then return nil end
    if type(fmt) == "function" then
        local ok, result = pcall(fmt, data)
        if ok then return result end
        return event_key  -- fallback on error
    end
    return event_key  -- unknown event: show name
end

-- ───────────────────────────────────────────────
-- Strip _raw helpers before JSON encoding
-- ───────────────────────────────────────────────

local function clean_for_json(tbl)
    if type(tbl) ~= 'table' then return tbl end
    local out = {}
    for k, v in pairs(tbl) do
        if k ~= '_raw' then
            out[k] = clean_for_json(v)
        end
    end
    return out
end

function Recorder.emit(event_key, data)
    if not cfg.EVENTS[event_key]  then return end
    if not Recorder.json_handle   then return end

    Recorder.seq = Recorder.seq + 1

    local entry = clean_for_json({
        seq   = Recorder.seq,
        ts    = os.time(),
        event = event_key,
    })
    if data then
        for k, v in pairs(data) do
            entry[k] = clean_for_json(v)
        end
    end

    -- JSON line
    local ok, encoded = pcall(json.encode, entry, {indent = false})
    if ok and encoded then
        Recorder.json_handle:write(encoded .. "\n")
        Recorder.json_handle:flush()
    else
        Recorder.json_handle:write('{"seq":' .. Recorder.seq .. ',"event":"ENCODE_ERROR","key":"' .. event_key .. '"}\n')
        Recorder.json_handle:flush()
    end

    -- Human-readable line
    if Recorder.txt_handle then
        local ts      = os.date("%H:%M:%S")
        local summary = txt_summary(event_key, data or {})
        if summary then
            Recorder.txt_handle:write("[" .. ts .. "] " .. summary .. "\n")
            Recorder.txt_handle:flush()
        end
    end
end

return Recorder
