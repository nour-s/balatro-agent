---
name: balatro
description: "Resume the BalatroRecorder mod project. Loads full context: architecture, all Balatro internals discovered, bugs fixed, and what to build next."
---

# BalatroRecorder — Full Resume Context

## What This Project Is

A Lua mod for the card game Balatro (via Lovely Injector) that records every run as a
deterministic, event-sourced JSONL trace — enabling replay, deep analysis, and eventual AI play.

**Working directory:** `/Users/mohamad.sabouny/sandbox/balatro/`  
**Git repo:** `main` branch, 3 commits, no remote.  
**Launch command:** `cd ~/Library/Application\ Support/Steam/steamapps/common/Balatro/Balatro.app/Contents/MacOS/ && sh run_lovely_macos.sh`  
**Logs output to:** `~/balatro-logs/seed_XYZ_N.jsonl`

---

## File Map

| File | Purpose |
|------|---------|
| `Mods/BalatroRecorder/config.lua` | LOG_DIR path, per-event enable/disable toggles |
| `Mods/BalatroRecorder/init.lua` | `startup()` wraps G.FUNCS; `update()` frame poller |
| `Mods/BalatroRecorder/hooks.lua` | All event handler functions called by wrappers |
| `Mods/BalatroRecorder/recorder.lua` | JSONL + .txt file I/O, `emit()` |
| `Mods/BalatroRecorder/snapshot.lua` | `compact()`, `hand_levels()`, `win_stats()`, `joker_graph()` |
| `Mods/BalatroRecorder/encoder.lua` | Card/Joker/Shop → JSON-safe plain tables |
| `Mods/BalatroRecorder/dkjson.lua` | Bundled JSON library |
| `Mods/BalatroRecorder/lovely/init.toml` | Lovely 0.9.0 patch file |
| `replay.html` | Static replay viewer (drag-and-drop .jsonl) |
| `skills/balatro.md` | This file |

---

## Events Recorded (current)

```
RUN_START       DECK_SNAPSHOT    JOKER_GRAPH      STATE_CHANGE
BLIND_OPTIONS   BLIND_SKIPPED    BOSS_BLIND_ACTIVE BOSS_REROLL
ROUND_START     HAND_DEALT       HAND_PLAYED      HAND_RESOLUTION
HAND_LEVELS     CARDS_DISCARDED  ROUND_RESOURCES  ROUND_WON
ROUND_LOST      SHOP_INVENTORY   SHOP_CLOSED      SHOP_BUY
SHOP_SELL       SHOP_REROLL      PACK_OPENED      CONSUMABLE_USED
CONSUMABLE_SNAPSHOT  DECK_CHANGE  MONEY_CHANGE    GAME_WIN
GAME_OVER
```

---

## G.STATES Reference

| ID | Name |
|----|------|
| 1  | SELECTING_HAND |
| 2  | HAND_PLAYED |
| 3  | DRAW_TO_HAND |
| 4  | GAME_OVER |
| 5  | SHOP |
| 6  | ROUND_EVAL |
| 7  | BLIND_SELECT |
| 8–18 | Pack-selection states (booster pack open) — confirmed 11 = BUFFOON_PACK |
| 19 | NEW_ROUND |

---

## Balatro Internals: Discovered Gotchas

These are non-obvious findings that caused bugs or required workarounds.
Read all of these before adding any new feature.

### Tags and blind state

- **`G.tags` is nil.** Tags earned from skipping blinds live in `G.GAME.tags`, not `G.tags`.
- **`G.GAME.blind_on_deck` advances immediately** when `skip_blind` runs. Capture `blind_before = G.GAME.blind_on_deck` and `tags_before = #G.GAME.tags` *before* calling `orig_skip_blind`; pass them as arguments to the hook.

### Blind initialisation timing

- `G.FUNCS.select_blind` fires **before** the blind object is populated. At that point `G.GAME.blind.name`, `.chips`, and `.key` are all nil.
- Fix: set `BREC.pending_round_start = true` in `on_blind_selected`. Emit ROUND_START from `on_state_change` when `to_id == 1` (SELECTING_HAND) — by then the blind is fully initialised.
- The boss key requires multiple fallback paths:
  ```lua
  local rr = G.GAME.round_resets or {}
  local boss_key = G.GAME.boss_blind_on_deck
                or (rr.blind_states and rr.blind_states.Boss and rr.blind_states.Boss.key)
                or (rr.blind_choices and rr.blind_choices.Boss and rr.blind_choices.Boss.key)
                or (G.GAME.boss and G.GAME.boss.key)
  ```

### ROUND_EVAL false positives

- State 6 (ROUND_EVAL) is entered briefly whenever you use a tarot or voucher while in the shop, not only after winning a round.
- Fix: in `on_state_change`, guard `on_round_won()` with `if from_id == 2 then` (state 2 = HAND_PLAYED).

### Buying boosters and vouchers via `use_card`

- In Balatro, clicking a booster pack or voucher in the shop calls **`G.FUNCS.use_card`**, not `buy_from_shop`.
- Detect them in `on_before_use_card` via `c1.ability.set == 'Booster'` or `== 'Voucher'`, emit SHOP_BUY, and return early.
- The card pick that follows (player selects a card from the pack) also comes through `use_card`, detectable by `G.STATE >= 8 and G.STATE <= 18`.

### Pack options (what the player was offered but didn't pick)

- `G.pack_cards` is a **CardArea object**, not a plain array. The actual card list is `G.pack_cards.cards`.
- Capture options in `on_before_use_card` when `G.STATE >= 8 and G.STATE <= 18`:
  ```lua
  for _, pc in ipairs((G.pack_cards and G.pack_cards.cards) or {}) do
      local k = pc.config and pc.config.center and pc.config.center.key
      table.insert(options, k or "unknown")
  end
  ```
- This includes the card being selected, so filter it out for the `ignored` list.

### Consumable before/after split

- All consumable effects happen inside `orig_use_card`. Anything captured *before* the call reflects pre-effect state (Emperor won't have added its tarots yet; Wheel of Fortune's edition won't be set).
- Fix: split into `on_before_use_card` (capture targets and intent) and `on_after_use_card` (emit events and snapshots). The JOKER_GRAPH and CONSUMABLE_SNAPSHOT must always fire after `orig_use_card`.

### `ability.extra` type

- For simple jokers (e.g. Jolly Joker), `ability.extra` is a **plain number** (the mult value), not a table.
- Calling `pairs(ability.extra)` on a number crashes with "bad argument #1 to 'pairs' (table expected, got number)".
- Fix: `if type(ability.extra) == 'table' then ... elseif type(ability.extra) == 'number' then result.extra = ability.extra end`

### Held-in-hand card effects during scoring

- Steel cards (x1.5 mult), Lucky card triggers, Stone chips, etc. are applied via `eval_card` with `context.cardarea == G.hand`.
- The result format for held cards: `result.hand = { Xmult_mod = 1.5 }` (Steel), `{ mult_mod = 20, dollars = 20 }` (Lucky trigger), etc.
- Capture in the `eval_card` wrapper alongside joker captures:
  ```lua
  if BREC.scoring_active and context and context.cardarea == G.hand and result then
      local hres = result.hand
      if hres and next(hres) then
          -- build step with source = "held_KS[Steel Card]", xmult/mult_delta/chips_delta/dollars
      end
  end
  ```

### Gold card payouts

- Gold cards give $3 *at the end of the round*, through `ease_dollars` during ROUND_EVAL — not during hand scoring.
- They can't be attributed in the scoring chain. Track them in `on_round_won` by inspecting `G.hand.cards` for `c.ability.effect == 'Gold Card'`, and emit the expected payout in `held_effects`.

### Rental joker costs

- Rental jokers charge $1/round. Also detectable at round end via `c.ability.rental == true` on joker cards in `G.jokers.cards`.

### BLIND_REWARD and interest across multiple ease_dollars calls

- When a round ends, Balatro calls `ease_dollars` multiple times in sequence: once for the blind reward, once for interest, possibly once more. All arrive with `BREC.money_source == "BLIND_REWARD"`.
- Fix: only clear `money_source` if it is *not* `"BLIND_REWARD"`:
  ```lua
  if BREC.money_source ~= "BLIND_REWARD" then BREC.money_source = nil end
  ```
  The source resets to nil when entering the shop (state 5).

### Deck changes after hands

- Midas Mask (gilding face cards), Vampire (removing enhancements), and Glass Card shatters all mutate the deck *during or after hand scoring*, not via a consumable.
- Fix: set `BREC.pending_deck_diff = true` at the end of `on_hand_result`. The frame poller in `update()` fingerprints the deck and emits DECK_CHANGE if it differs.

### HAND_DEALT timing

- `G.hand.cards` is populated by the time `SELECTING_HAND` (state 1) is entered.
- Emit HAND_DEALT on *every* `to_id == 1` transition (not only at round start) to capture redraws after each discard.

### `????` hand type

- Boss blinds The Eye, The Window, and The Serpent hide hand classification. Balatro stores the literal string `"????"` as the hand_type and `"?"` for chips/mult. This is correct recording, not a bug.

### G.FUNCS.game_over

- This function is called with `won = true` on a game win, `won = false` on a loss (death).
- Detecting game over via state machine (state 4) fires too early and misses wins. Wrap `G.FUNCS.game_over` directly:
  ```lua
  if G.FUNCS.game_over then
      local orig = G.FUNCS.game_over
      G.FUNCS.game_over = function(won, ...)
          if BREC.active then
              safe(h.on_game_over, won)
              BREC.active = false
          end
          orig(won, ...)
      end
  end
  ```

### Lovely Injector init.toml requirements

- Requires a `[manifest]` section. The `id` and `name` keys produce WARN messages but are harmless — only `version` is read.
- Module patches load Lua files from the mod directory by name. Pattern patches inject code into game files.

---

## BREC Global State Fields

```lua
BREC = {
    active              = false,       -- true while a run is recording
    scoring_active      = false,       -- true inside evaluate_play
    scoring_chain       = {},          -- joker + held-card contributions this hand
    scoring_base        = {},          -- base hand chips/mult
    state_before_hand   = nil,         -- compact() snapshot at play time
    state_before_discard= nil,
    play_cards          = nil,
    discard_cards       = nil,
    money_source        = nil,         -- attribution for next ease_dollars call(s)
    rng_index           = 0,
    prev_state          = nil,
    prev_dollars        = nil,
    shop_reroll_count   = 0,
    pending_shop_inventory = false,
    pending_deck_diff   = false,       -- set after hand or consumable; frame loop diffs deck
    deck_snapshot       = nil,         -- last known deck fingerprint for diffing
    last_pack_key       = nil,         -- key of last booster opened (for PACK_OPENED)
    pending_round_start = false,       -- set by select_blind; cleared when SELECTING_HAND reached
    _pending_use_type   = nil,         -- 'Booster'|'Voucher'|'PackPick'|'Consumable'
    _pending_consumable = nil,         -- data for current consumable use
    _pending_pack_pick  = nil,         -- data for current pack card pick
    last_hand_info      = nil,         -- {hand_type, chips, mult} captured inside evaluate_play
    run_pending_init    = false,       -- set by start_run; cleared when BLIND_SELECT reached
    _state_frame        = 0,           -- frame counter (used by bridge if implemented)
}
```

---

## Summary Script (run on any log file)

```bash
python3 /tmp/run_summary.py   # hardcoded to seed_5RKI52EE_3.jsonl — edit path as needed
```

The script at `/tmp/run_summary.py` (and `/tmp/summarize_u914.py`) parses a JSONL and prints:
- Ante/round headers
- dealt/discard/play lines with card notation
- hand type and chips×mult=score
- shop contents, buys, rerolls, left-behind items
- money changes with source attribution
- GAME_WIN / GAME_OVER

To run on a new file: copy the script and change the `open(...)` path at line 3.

---

## What's Known to Still Be Wrong / Unverified

| Issue | Status |
|-------|--------|
| Boss blind key in BLIND_OPTIONS | Multiple fallback paths added but logs show nil — needs live verification |
| Pack options `G.pack_cards.cards` | Fixed in code but not yet tested in a new run with packs |
| HAND_DEALT cards populated at state-1 entry | Timing assumed correct; needs live verification |
| `????` hand type chips/mult captured as `"?"` | Correct by design — boss blind hides classification |
| MONEY_CHANGE sources tagged UNKNOWN | BLIND_REWARD works; interest attribution confirmed. Economy tags ($4 from skipping) still show UNKNOWN |

---

## Next Feature: Action Bridge (not yet implemented)

Plan at: `~/.claude/plans/someone-create-a-tool-idempotent-thacker.md`

Build bidirectional control via two files in `~/balatro-logs/`:

| File | Writer | Reader | Purpose |
|------|--------|--------|---------|
| `state.json` | mod every 30 frames | Claude | Current game state for decisions |
| `command.json` | Claude | mod every frame | Action to execute; mod deletes after reading |

### Command protocol
```json
{ "action": "play",           "hand_indices": [1, 3, 5] }
{ "action": "discard",        "hand_indices": [2, 4] }
{ "action": "buy",            "area": "joker|voucher|booster", "slot": 1 }
{ "action": "sell",           "joker_slot": 2 }
{ "action": "reroll_shop" }
{ "action": "select_blind" }
{ "action": "skip_blind" }
{ "action": "reroll_boss" }
{ "action": "use_consumable", "consumable_slot": 1, "hand_indices": [1, 2] }
```

### Key implementation note for play/discard
```lua
G.hand.highlighted = {}
for _, idx in ipairs(cmd.hand_indices) do
    local c = G.hand.cards[idx]
    if c then table.insert(G.hand.highlighted, c) end
end
G.FUNCS.play_cards_from_highlighted({config={}})
```

### Files needed
- **New:** `Mods/BalatroRecorder/bridge.lua` — `write_state()`, `read_command()`, `execute(cmd)`
- **Modified:** `init.lua` update() — call bridge every 30 frames and on each frame for commands
- **Modified:** `lovely/init.toml` — add bridge.lua module patch
