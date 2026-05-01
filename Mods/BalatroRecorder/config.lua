-- BalatroRecorder configuration
-- Edit LOG_DIR to change where log files are saved.
-- Set any event to false to suppress it from the log.

local home = os.getenv("HOME") or "~"

return {
    LOG_DIR = home .. "/balatro-logs",

    EVENTS = {
        RUN_START          = true,
        DECK_SNAPSHOT      = true,
        RNG_CALL           = false,  -- very verbose; enable only for replay analysis
        STATE_CHANGE       = true,
        BLIND_OPTIONS      = true,
        BOSS_BLIND_ACTIVE  = true,
        BOSS_REROLL        = true,
        ROUND_START        = true,
        JOKER_GRAPH        = true,
        HAND_PLAYED        = true,
        HAND_RESOLUTION    = true,
        CARDS_DISCARDED    = true,
        ROUND_RESOURCES    = true,
        ROUND_WON          = true,
        ROUND_LOST         = true,
        SHOP_INVENTORY     = true,
        SHOP_BUY           = true,
        SHOP_SELL          = true,
        SHOP_REROLL        = true,
        PACK_OPENED        = true,
        CONSUMABLE_USED    = true,
        CONSUMABLE_SNAPSHOT= true,
        DECK_CHANGE        = true,
        MONEY_CHANGE       = true,
        GAME_WIN           = true,
        GAME_OVER          = true,
    },
}
