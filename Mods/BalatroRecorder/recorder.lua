-- Recorder: manages log file handles and emits structured events.

local json = require("dkjson")
local cfg  = require("brec_config")

local Recorder = {
    seq        = 0,
    txt_handle = nil,
    json_handle= nil,
    run_seed   = nil,
    run_number = nil,
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

local function next_run_number(seed)
    local n = 1
    while true do
        local path = cfg.LOG_DIR .. "/seed_" .. seed .. "_" .. n .. ".jsonl"
        local f = io.open(path, "r")
        if not f then break end
        f:close()
        n = n + 1
    end
    return n
end

function Recorder.open_run(seed)
    ensure_dir(cfg.LOG_DIR)
    Recorder.run_seed   = seed
    local n             = next_run_number(seed)
    Recorder.run_number = n
    Recorder.seq        = 0

    local base = cfg.LOG_DIR .. "/seed_" .. seed .. "_" .. n

    Recorder.json_handle = io.open(base .. ".jsonl", "w")
    Recorder.txt_handle  = io.open(base .. ".txt",   "w")

    if Recorder.txt_handle then
        local h = Recorder.txt_handle
        h:write("=== BALATRO RUN RECORDER ===\n")
        h:write("Seed:  " .. tostring(seed) .. "\n")
        h:write("Run#:  " .. tostring(n)    .. "\n")
        h:write("Date:  " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
        h:write(string.rep("=", 40) .. "\n\n")
        h:flush()
    end
end

function Recorder.close_run()
    if Recorder.txt_handle  then Recorder.txt_handle:close();  Recorder.txt_handle  = nil end
    if Recorder.json_handle then Recorder.json_handle:close(); Recorder.json_handle = nil end
    Recorder.run_seed   = nil
    Recorder.run_number = nil
end

-- Build a one-line human summary for .txt
local function txt_summary(event_key, action, resolution)
    local parts = { event_key }
    if action then
        if action.cards then
            local enc = require("encoder")
            local shorts = {}
            for _, c in ipairs(action.cards) do
                if c._raw then
                    table.insert(shorts, enc.card_short(c._raw))
                elseif c.value and c.suit then
                    table.insert(shorts, (c.value):sub(1,1) .. (c.suit):sub(1,1))
                end
            end
            if #shorts > 0 then
                table.insert(parts, "[" .. table.concat(shorts, " ") .. "]")
            end
        end
        if action.item_key then table.insert(parts, action.item_key) end
        if action.blind_key then table.insert(parts, action.blind_key) end
    end
    if resolution then
        if resolution.hand_type  then table.insert(parts, "→ " .. resolution.hand_type) end
        if resolution.score      then table.insert(parts, "score=" .. tostring(resolution.score)) end
        if resolution.final_score then table.insert(parts, "total=" .. tostring(resolution.final_score)) end
        if resolution.delta      then
            local d = resolution.delta
            table.insert(parts, (d >= 0 and "+" or "") .. tostring(d) .. "$")
        end
    end
    return table.concat(parts, "  ")
end

-- Strip _raw helpers before JSON encoding
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
        -- fallback: write error marker
        Recorder.json_handle:write('{"seq":' .. Recorder.seq .. ',"event":"ENCODE_ERROR","key":"' .. event_key .. '"}\n')
        Recorder.json_handle:flush()
    end

    -- Human-readable line
    if Recorder.txt_handle then
        local ts  = os.date("%H:%M:%S")
        local summary = txt_summary(event_key, data and data.action, data and data.resolution)
        Recorder.txt_handle:write("[" .. ts .. "] " .. summary .. "\n")
        Recorder.txt_handle:flush()
    end
end

return Recorder
