# balatro-agent

A local LLM agent that plays [Balatro](https://store.steampowered.com/app/2379780/Balatro/) autonomously. A Lua mod hooks into the game loop via [Lovely Injector](https://github.com/nickmqb/lovely-injector) and exposes a file-based IPC bridge. An Ollama-powered Python agent reads game state, retrieves context from a RAG index over the full Balatro wiki, and writes back actions — all at human pace.

## How it works

```
Balatro (Lua) ──write──▶ ~/balatro-logs/state.json
                                      │
                                 agent.py reads state,
                                 queries RAG wiki,
                                 asks Ollama for action
                                      │
Balatro (Lua) ──read──▶ ~/balatro-logs/command.json
```

1. The `BalatroRecorder` mod writes the full game state (hand, jokers, shop, blind, dollars…) to `state.json` every frame.
2. `agent.py` reads state, retrieves relevant wiki articles via RAG, sends a prompt to Ollama, and writes the chosen action to `command.json`.
3. The mod reads and executes the command, then deletes the file — agent polls until it's gone and loops.

## Requirements

- Balatro (Steam, Mac)
- [Lovely Injector](https://github.com/nickmqb/lovely-injector) installed into `Balatro.app/Contents/MacOS/`
- [Ollama](https://ollama.com/) running locally with a model pulled, e.g.:
  ```bash
  ollama pull qwen2.5:7b
  ollama pull nomic-embed-text   # for RAG
  ```
- Python 3.11+
  ```bash
  pip install anthropic lancedb sentence-transformers ollama
  ```

## Setup

**1. Install the mod**

```bash
ln -s ~/sandbox/balatro/Mods/BalatroRecorder \
      ~/Library/Application\ Support/Balatro/Mods/BalatroRecorder
```

**2. Build the RAG index** (one-time, ~2 min, embeds 262 wiki articles)

```bash
python3 rag.py --build
```

**3. Run the agent**

```bash
python3 agent.py --model qwen2.5:7b   # with RAG wiki context (default)
python3 agent.py --no-rag             # faster, skips wiki retrieval
```

The agent launches Balatro if it's not already running and plays until game over.

## Scripts

| Script | Purpose |
|--------|---------|
| `agent.py` | Autonomous Ollama agent — reads state, picks action, loops |
| `rag.py` | Embeds/indexes wiki; retrieves relevant articles each turn |
| `analyze_run.py` | Post-game run analysis via Anthropic API (`ANTHROPIC_API_KEY` required) |
| `benchmark.py` | Latency + quality benchmark across models and game states |
| `merge_runs.py` | Merge JSONL run logs |
| `scrape_wiki.py` | Re-scrape [balatrowiki.org](https://balatrowiki.org) into `wiki/` |
| `saves-snapshot.sh` | Snapshot/restore save files; force-quit Balatro before a loss |

## Mod architecture (`Mods/BalatroRecorder/`)

| File | Role |
|------|------|
| `bridge.lua` | IPC layer — writes state.json, reads and executes command.json |
| `snapshot.lua` | Serializes full game state into JSON each frame |
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
python3 benchmark.py --model qwen2.5:7b --rag --states 10
```

Runs 10 sampled game states through the full RAG + inference pipeline and reports latency, tokens/sec, and decision quality.
