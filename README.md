# balatro-agent

A Lua IPC bridge that lets an AI play [Balatro](https://store.steampowered.com/app/2379780/Balatro/). A Lovely Injector mod serialises full game state to a file and executes actions written back to another file. Any agent that can read and write files can drive the game — the primary client is **Claude Code** (via the `/play` skill), with an optional autonomous Ollama agent included for unattended play.

## How it works

```
Balatro (Lua mod)
  └─ writes ──▶ ~/balatro-logs/state.json
  └─ reads  ──▶ ~/balatro-logs/command.json
                        │
          ┌─────────────┴─────────────┐
          │                           │
    Claude Code                   agent.py
  (primary client)          (autonomous Ollama loop)
  reads state with            reads state, queries
  Read tool, writes           RAG wiki, asks LLM,
  command with Write          writes command, loops
```

1. The `BalatroRecorder` mod writes full game state (hand, jokers, shop, blind, dollars…) to `state.json` every frame.
2. The client reads state, decides an action, and writes it to `command.json`.
3. The mod executes the command and deletes the file; the client polls until it's gone and loops.

## Requirements

- Balatro (Steam, Mac)
- [Lovely Injector](https://github.com/nickmqb/lovely-injector) installed into `Balatro.app/Contents/MacOS/`
- For the autonomous agent: [Ollama](https://ollama.com/) running locally
  ```bash
  ollama pull qwen3:14b
  ollama pull nomic-embed-text   # for RAG
  ```
- Python 3.11+ (autonomous agent only)
  ```bash
  pip install lancedb ollama
  ```

## Setup

**1. Install the mod**

```bash
ln -s ~/sandbox/balatro/Mods/BalatroRecorder \
      ~/Library/Application\ Support/Balatro/Mods/BalatroRecorder
```

Launch Balatro via Steam (Lovely must already be injected into the binary). State files appear in `~/balatro-logs/` once the mod loads.

---

### Play with Claude Code (primary path)

Load the `/play` skill in Claude Code — it covers launch, file locations, the full bridge protocol, command formats, game states, and strategy. Claude reads `state.json` with the Read tool and writes `command.json` with the Write tool.

```
/play
```

No additional setup beyond the mod install above.

---

### Run the autonomous agent

**2. Build the RAG index** (one-time, ~2 min, embeds 262 wiki articles)

```bash
python3 rag.py --build
```

**3. Run the agent**

```bash
python3 agent.py --model qwen3:14b   # with RAG wiki context (default)
python3 agent.py --no-rag             # faster, skips wiki retrieval
```

## Scripts

| Script | Purpose |
|--------|---------|
| `agent.py` | Autonomous agent — reads state, picks action via Ollama, loops |
| `rag.py` | Builds/queries RAG index over the Balatro wiki |
| `analyze_run.py` | Post-game run analysis via Anthropic API (`ANTHROPIC_API_KEY` required) |
| `benchmark.py` | Latency + quality benchmark across models and game states |
| `merge_runs.py` | Merge JSONL run logs |
| `scrape_wiki.py` | Re-scrape [balatrowiki.org](https://balatrowiki.org) into `wiki/` |
| `saves-snapshot.sh` | Snapshot/restore save files; force-quit Balatro before a loss |

## Mod architecture (`Mods/BalatroRecorder/`)

| File | Role |
|------|------|
| `bridge.lua` | IPC layer — writes state.json, reads and executes command.json |
| `snapshot.lua` | Serialises full game state into JSON each frame |
| `init.lua` | Hooks into the game loop, polls every ~30 frames |
| `encoder.lua` | Pure-Lua JSON encoder |
| `hooks.lua` | Event hooks (round start, card play, shop enter, …) |

## Supported commands

| Game state | Commands |
|------------|---------|
| `BLIND_SELECT` | `select_blind`, `skip_blind`, `reroll_boss` |
| `SELECTING_HAND` | `play {hand_indices}`, `discard {hand_indices}` |
| `ROUND_EVAL` | `cash_out` |
| `SHOP` | `buy {area, slot}`, `sell {joker_slot}`, `reroll_shop`, `next_round` |
| Any | `start_run [deck/stake/seed]`, `use_consumable {slot}` |

`hand_indices` are 1-based positions from `state.json`'s `hand[]` array.

## Benchmarking

```bash
python3 benchmark.py --model qwen3:14b --rag --states 10
```

Runs 10 sampled game states through the full RAG + inference pipeline and reports latency, tokens/sec, and decision quality.
