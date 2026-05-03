-- Converts live Balatro game objects into plain Lua tables safe for JSON serialization.

local Encoder = {}

local RANK_SHORT = {
    Ace='A', ['2']='2', ['3']='3', ['4']='4', ['5']='5',
    ['6']='6', ['7']='7', ['8']='8', ['9']='9', ['10']='T',
    Jack='J', Queen='Q', King='K',
}
local SUIT_SHORT = { Spades='S', Hearts='H', Diamonds='D', Clubs='C' }

local function card_edition(c)
    if not c.edition then return nil end
    if c.edition.negative    then return "negative"    end
    if c.edition.polychrome  then return "polychrome"  end
    if c.edition.holo        then return "holo"        end
    if c.edition.foil        then return "foil"        end
    return nil
end

-- Full playing card encoding (for JSON)
function Encoder.card(c)
    if not c then return nil end
    local base    = c.base    or {}
    local ability = c.ability or {}
    local result  = {
        suit     = base.suit,
        value    = base.value,
        nominal  = base.nominal,
        edition  = card_edition(c),
        seal     = c.seal or nil,
    }
    local enh = ability.effect
    if enh and enh ~= '' and enh ~= 'Base' then
        result.enhancement = enh
    end
    if (base.times_played or 0) > 0 then
        result.times_played = base.times_played
    end
    return result
end

-- Short human-readable notation for .txt log: "AH[foil][gold_seal]"
function Encoder.card_short(c)
    if not c then return "?" end
    local base = c.base or {}
    local r = RANK_SHORT[base.value] or base.value or '?'
    local s = SUIT_SHORT[base.suit]  or base.suit  or '?'
    local short = r .. s
    local ed = card_edition(c)
    if ed then short = short .. '[' .. ed .. ']' end
    if c.seal then short = short .. '[' .. string.lower(c.seal) .. '_seal]' end
    local enh = c.ability and c.ability.effect
    if enh and enh ~= '' and enh ~= 'Base' then
        short = short .. '[' .. string.lower(string.gsub(enh, ' ', '_')) .. ']'
    end
    return short
end

-- Joker / consumable center key
local function center_key(c)
    local cfg = c.config or {}
    local ctr = cfg.center or {}
    return ctr.key or (c.ability and c.ability.name) or "unknown"
end

-- Full joker encoding (for JSON)
function Encoder.joker(j)
    if not j then return nil end
    local ability = j.ability or {}
    local result = {
        key     = center_key(j),
        name    = ability.name,
        set     = ability.set,
        level   = ability.level or 1,
        edition = card_edition(j),
    }
    if ability.eternal     then result.eternal        = true end
    if ability.perishable  then
        result.perishable  = true
        result.perish_tally = ability.perish_tally
    end
    if ability.rental      then result.rental         = true end
    -- Capture any numeric extra fields; extra can be a plain number on simple jokers
    if type(ability.extra) == 'table' then
        local extras = {}
        for k, v in pairs(ability.extra) do
            if type(v) == 'number' or type(v) == 'boolean' then
                extras[k] = v
            end
        end
        if next(extras) then result.extra = extras end
    elseif type(ability.extra) == 'number' then
        result.extra = ability.extra
    end
    return result
end

-- Consumable card (tarot/planet/spectral) encoding
function Encoder.consumable(c)
    if not c then return nil end
    return {
        key  = center_key(c),
        name = (c.ability or {}).name,
        set  = (c.ability or {}).set,
    }
end

-- Shop item encoding
function Encoder.shop_item(c)
    if not c then return nil end
    local ability = c.ability or {}
    local cfg_ctr = (c.config or {}).center or {}
    return {
        key    = center_key(c),
        name   = ability.name,
        set    = ability.set or cfg_ctr.set,
        cost   = c.cost,
        edition = card_edition(c),
    }
end

-- Full deck as array
function Encoder.deck(cards)
    local out = {}
    for _, c in ipairs(cards or {}) do
        table.insert(out, Encoder.card(c))
    end
    return out
end

-- Joker list (positional).
-- Optional set_filter ("Joker" or "Voucher") restricts output to that set.
-- G.jokers.cards contains both jokers and owned vouchers — Balatro stores them
-- together. We split them in the output so the agent sees separate lists and
-- vouchers don't consume joker slot counts.
function Encoder.joker_list(joker_cards, set_filter)
    local out = {}
    local pos = 0
    for i, j in ipairs(joker_cards or {}) do
        local item_set = (j.ability or {}).set
        if not set_filter or item_set == set_filter then
            local enc = Encoder.joker(j)
            if enc then
                enc.pos = pos
                pos = pos + 1
                table.insert(out, enc)
            end
        end
    end
    return out
end

-- Consumable hand list
function Encoder.consumable_list(consumable_cards)
    local out = {}
    for _, c in ipairs(consumable_cards or {}) do
        table.insert(out, Encoder.consumable(c))
    end
    return out
end

-- Shop inventory across all card areas
function Encoder.shop_inventory()
    local slots = {}
    if G.shop_jokers then
        for i, c in ipairs(G.shop_jokers.cards or {}) do
            local item = Encoder.shop_item(c)
            if item then item.slot = "joker_" .. i; table.insert(slots, item) end
        end
    end
    if G.shop_vouchers then
        for i, c in ipairs(G.shop_vouchers.cards or {}) do
            local item = Encoder.shop_item(c)
            if item then item.slot = "voucher_" .. i; table.insert(slots, item) end
        end
    end
    if G.shop_booster then
        for i, c in ipairs(G.shop_booster.cards or {}) do
            local item = Encoder.shop_item(c)
            if item then item.slot = "booster_" .. i; table.insert(slots, item) end
        end
    end
    -- consumables section of shop (planets/tarots offered)
    if G.consumeables then
        for i, c in ipairs(G.consumeables.cards or {}) do
            if c.area == G.shop_jokers or c.area == G.shop_booster then
                -- skip already captured
            else
                local item = Encoder.shop_item(c)
                if item and item.cost then  -- only priced items are for sale
                    item.slot = "consumable_" .. i; table.insert(slots, item)
                end
            end
        end
    end
    return slots
end

return Encoder
