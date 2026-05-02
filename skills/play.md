---
name: play
description: "Resume playing Balatro as an AI agent. Covers launch, file locations, bridge protocol, exact command formats, game states, strategy, and all known bugs. Load this before doing anything else in a play session."
---

# Playing Balatro — AI Agent Resume Guide

## TL;DR
- User runs the game. You read `~/balatro-logs/state.json` and write `~/balatro-logs/command.json`.
- Command is executed when the file disappears (game deletes it after consuming).
- All actions use `hand_indices` (1-based `idx` from state.json), not card strings.

---

## Launch

**Step 1 — Check if already running** by reading state.json timestamp:
```bash
ls -la ~/balatro-logs/state.json
```
If the timestamp is recent (within last 60s) AND state is not GAME_OVER, the game is running — skip to reading state. Do NOT launch a second instance.

If state.json is stale or missing, the game is NOT running. `pgrep` is unreliable in this sandbox — use the file timestamp as the source of truth.

**Step 2 — Kill any zombie process** before launching:
```bash
pkill -x Balatro 2>/dev/null; sleep 1
```

**Step 3 — Delete stale command.json** — a leftover command from a previous session will be consumed on startup and can crash the game:
```bash
rm -f ~/balatro-logs/command.json ~/balatro-logs/command.json~
```

**Step 4 — Launch:**
```bash
cd ~/Library/Application\ Support/Steam/steamapps/common/Balatro/Balatro.app/Contents/MacOS/ && sh run_lovely_macos.sh >> ~/balatro-logs/launch.log 2>&1 &
```
Steam must be running first. Without Lovely Injector the mod doesn't load and no bridge files appear.

**Step 5 — Confirm it's running:** poll state.json every 3s until the timestamp updates and state is not SPLASH. Takes ~15-20s.
```bash
sleep 15 && ls -la ~/balatro-logs/state.json && cat ~/balatro-logs/state.json
```
If state.json timestamp hasn't changed after 20s, the launch failed — check launch.log.

Mod files live in:
```
~/sandbox/balatro/Mods/BalatroRecorder/
```
Symlinked from `~/Library/Application Support/Balatro/Mods/BalatroRecorder/` — editing files in the sandbox path updates the installed mod. **Changes only take effect after a game restart** (Lua `require()` caches modules).

Logs directory: `~/balatro-logs/`

---

## Reading State

Use the Read tool:
```
~/balatro-logs/state.json
```

Full schema:
```json
{
  "state": "SELECTING_HAND",
  "ante": 1,
  "round": 1,
  "hands_left": 4,
  "discards_left": 3,
  "chips_scored": 220,
  "chips_needed": 300,
  "dollars": 8,
  "hand": [
    {"idx": 1, "suit": "Spades", "value": "King", "nominal": 10},
    {"idx": 2, "suit": "Spades", "value": "Queen", "nominal": 10},
    {"idx": 3, "suit": "Hearts", "value": "7",    "nominal": 7}
  ],
  "jokers": [
    {"pos": 0, "key": "j_ice_cream", "name": "Ice Cream", "extra": {"chips": 95, "chip_mod": 5}}
  ],
  "consumables": [],
  "shop": {
    "jokers":   [{"slot": 1, "key": "j_foo", "name": "Foo Joker", "cost": 6}],
    "vouchers": [{"slot": 1, "key": "v_foo", "name": "Foo Voucher", "cost": 10}],
    "boosters": [{"slot": 1, "key": "p_foo", "name": "Foo Pack",   "cost": 4}]
  }
}
```

**`idx`** is the 1-based position of each card in hand — use it for all play/discard commands.

**`chips_needed` bug (partially fixed):** Was always 0 due to reading the wrong Balatro field. The fix in snapshot.lua tries `G.GAME.blind.chips` then falls back to `G.GAME.blind.config.blind.chips`. If it still shows 0, use this table:

| Ante | Small | Big   | Boss   |
|------|-------|-------|--------|
| 1    | 300   | 450   | 600    |
| 2    | 800   | 1200  | 1600   |
| 3    | 2000  | 3000  | 4000   |
| 4    | 5000  | 7500  | 10000  |
| 5    | 11000 | 16500 | 22000  |
| 6    | 20000 | 30000 | 40000  |
| 7    | 35000 | 52500 | 70000  |
| 8    | 50000 | 75000 | 100000 |

Round within ante: `round` in state.json is an absolute counter. `((round-1) % 3) + 1` gives blind type: 1=Small, 2=Big, 3=Boss.

---

## Sending Commands

Write to `~/balatro-logs/command.json` using the Write tool. The game polls every frame, executes, then **deletes** the file. Confirm execution by re-reading — if the file is gone, the command ran.

**Never write a new command while command.json still exists.** Check first.

---

## Full Command Reference

### BLIND_SELECT (state == "BLIND_SELECT")

```json
{"action": "select_blind"}
{"action": "skip_blind"}
{"action": "reroll_boss"}
```

**Critical:** `select_blind` and `skip_blind` now look up the real Blind object from `G.GAME.round_resets.blind_choices` and pass it as `ref_table`. This is required for the chip target to be properly initialized. Without it, blinds start with 0 chips required and any score wins. This fix is in bridge.lua — requires a restart to be active.

### SELECTING_HAND (state == "SELECTING_HAND")

```json
{"action": "play",    "hand_indices": [1, 2, 3, 4, 5]}
{"action": "discard", "hand_indices": [3, 6, 7]}
```

`hand_indices` are the `idx` values from the `hand[]` array — 1-based, exactly as shown in state.json. **Do NOT use card strings like "KS" or "9H" — the bridge ignores them.**

### ROUND_EVAL (state == "ROUND_EVAL")

```json
{"action": "cash_out"}
```

Transitions to SHOP.

### SHOP (state == "SHOP")

```json
{"action": "buy",          "area": "joker",   "slot": 1}
{"action": "buy",          "area": "voucher",  "slot": 1}
{"action": "sell",         "joker_slot": 2}
{"action": "reroll_shop"}
{"action": "next_round"}
```

`slot` is 1-based from `shop.jokers[]`, `shop.vouchers[]`, or `shop.boosters[]` in state.json.
`joker_slot` is 1-based from the `jokers[]` array.
`next_round` calls `G.FUNCS.toggle_shop` to leave the shop and go to BLIND_SELECT.

**Cannot open booster packs** — `buy` with `area: "booster"` is not implemented. Skip packs entirely.

### Main menu / any state

```json
{"action": "start_run"}
{"action": "start_run", "deck": "b_red", "stake": 1, "seed": "ABCD1234"}
{"action": "start_run", "continue": true}
```

**Always ask the user first: continue the saved run or start a new one?**
- `{"action": "start_run"}` — starts a **new run** with optional `deck`/`stake`/`seed`.
- `{"action": "start_run", "continue": true}` — resumes the saved run (loads `save.jkr`).

Both routes go through `G.FUNCS.start_run` which calls `G:delete_run()` → `G.MAIN_MENU_UI:remove()`. This is required to dismiss the main menu overlay (the locked-card hint card); skipping it leaves that UI element floating over the entire run.

### Any state

```json
{"action": "use_consumable", "consumable_slot": 1}
{"action": "use_consumable", "consumable_slot": 1, "hand_indices": [2, 3]}
```
`consumable_slot` is 1-based from `consumables[]` in state.json. `hand_indices` only needed for tarot cards that target cards (e.g. The Empress). Planet cards need no `hand_indices`. Verified working for planet cards.

---

## State Machine

```
BLIND_SELECT (7)
  → select_blind → DRAW_TO_HAND (3) → SELECTING_HAND (1)
  → skip_blind   → BLIND_SELECT (7)  [next blind offered]

SELECTING_HAND (1)
  → play    → HAND_PLAYED (2) → DRAW_TO_HAND (3) → SELECTING_HAND (1)
                              → ROUND_EVAL (6)    [blind beaten]
                              → GAME_OVER (4)     [out of hands]
  → discard → DRAW_TO_HAND (3) → SELECTING_HAND (1)

ROUND_EVAL (6)
  → cash_out → SHOP (5)

SHOP (5)
  → next_round → BLIND_SELECT (7)
```

**States to wait on (no action):** HAND_PLAYED (2), DRAW_TO_HAND (3) — these are animation states. Re-read state.json until the state changes.

**GAME_OVER (4):** Stop. Report ante/round reached and jokers held at death. Ask user whether to continue.

---

## Playing Strategy

### BLIND_SELECT
- Always `select_blind` for Small and Big blinds.
- Skip Boss blind only if: hand is weak AND skip tag is high-value (free Joker tag, Spectral pack tag).
- Otherwise always select.

### SELECTING_HAND — Hand Priority
Best to worst:
1. Straight Flush / Royal Flush
2. Four of a Kind
3. Full House
4. Flush (5 same suit)
5. Straight (5 consecutive)
6. Three of a Kind
7. Two Pair
8. Pair
9. High Card (last resort)

**Discard first if ALL hold:**
- `discards_left >= 1`
- `hands_left >= 2`
- Best current hand is Pair or worse
- Hand contains a 4-card draw (flush or straight) or 3-of-a-kind draw

**What to discard:** keep the best partial combination, discard the outliers. Never discard all 5 speculatively.

**Emergency (hands_left == 1):** play best available, no discard.

### SHOP — Buy Priority
1. **Jokers first** — the win condition. Buy if it scores for hands you play (pairs, flushes, etc.), gives economy (interest/income), or is unconditional mult/chips.
2. **Planet cards** — upgrade the hand type you play most. Worth buying.
3. **Tarot cards** — situational. Skip unless clearly useful (e.g., The Empress on enhanceable cards).
4. **Reroll ($5)** — only if shop is useless AND `dollars > $8`.
5. **Skip boosters** — can't open packs, money wasted.
6. **Skip vouchers** — generally too expensive early; buy only on vouchers that give reroll discount or hand-size upgrades if dollars > $15.
- Reserve at least $2 buffer after any purchase.
- If all 5 joker slots full: only sell the weakest joker if the shop joker is clearly stronger.
- End shop with `next_round`.

---

## Known Bugs & Status

| Bug | Status | Notes |
|-----|--------|-------|
| `chips_needed` always 0 | **Partially fixed** in snapshot.lua | Falls back to config path; use reference table if still 0 |
| `select_blind` / `skip_blind` sets 0 chip requirement | **Fixed** in bridge.lua | Now passes real Blind ref_table from `round_resets.blind_choices` |
| Can't open booster packs | **Not fixed** | Skip packs in shop |
| `next_round` (leave shop) | **Fixed** in bridge.lua | Uses `G.FUNCS.toggle_shop` |
| Card strings in play/discard ignored | **By design** | Always use `hand_indices` |
| state.json silent during SPLASH | **Fixed** in bridge.lua | Now writes `{"state":"SPLASH"}` when G.GAME is nil so agent knows game is loading |
| Main menu overlay stuck on screen | **Fixed** in bridge.lua | `start_run` now routes through `G.FUNCS.start_run` so `G:delete_run()` fires and removes `G.MAIN_MENU_UI` |
| Module cache: edits need restart | **By design** | Restart game after any bridge.lua / snapshot.lua change |

---

## Play Session Checklist

1. **Verify the game is running** — use the Launch section checklist (timestamp check, kill zombie, delete stale command.json, launch, confirm).
2. Read state.json — confirm it exists and `state` is a known value
3. If state is SPLASH: wait, re-read every 3s until it changes (game still loading)
4. Confirm command.json does NOT exist (no stuck command)
5. If state is MENU: ask user — continue saved run or start new? Then send `start_run`
6. If state is BLIND_SELECT: `select_blind`
7. If state is SELECTING_HAND: read hand, pick best action
8. After writing command.json: re-read state.json until file is gone (command executed)
9. If state is ROUND_EVAL: `cash_out`
10. If state is SHOP: buy jokers, then `next_round`
11. If state is HAND_PLAYED or DRAW_TO_HAND (animation): re-read and wait, no action
12. If state is GAME_OVER: stop and report

---

## Critical Files

| File | Purpose |
|------|---------|
| `~/balatro-logs/state.json` | Read every turn — current game state |
| `~/balatro-logs/command.json` | Write to act — deleted by game on execution |
| `Mods/BalatroRecorder/bridge.lua` | IPC layer: write_state, read_command, execute |
| `Mods/BalatroRecorder/snapshot.lua` | compact() — what gets serialized into state.json |
| `Mods/BalatroRecorder/init.lua` | Hooks and frame polling (calls bridge every ~30 frames) |
| `skills/balatro.md` | Deep reference: recorder architecture, all event types, Balatro internals |
