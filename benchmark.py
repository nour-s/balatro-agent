#!/usr/bin/env python3
"""
Balatro local-model benchmark.

Extracts real SELECTING_HAND game states from ~/balatro-logs/*.jsonl,
sends each one to Ollama, and measures latency + tokens/sec.

Usage:
    python3 benchmark.py [--model MODEL] [--url URL] [--states N]
"""

import argparse
import glob
import json
import os
import sys
import time
from pathlib import Path

# ── defaults ────────────────────────────────────────────────────────────────
OLLAMA_BASE_URL = "http://localhost:11434"
DEFAULT_MODEL   = "llama3.2:3b"
LOG_DIR         = os.path.expanduser("~/balatro-logs")
NUM_STATES      = 10

# ── strategy system prompt (same text the agent will use) ────────────────────
SYSTEM_PROMPT = """You are an AI playing Balatro, a roguelike poker card game.
You receive the current game state as JSON and must respond with EXACTLY one JSON
action object and nothing else — no explanation, no markdown, just raw JSON.

== GAME STATES & ACTIONS ==

BLIND_SELECT:
  {"action": "select_blind"}
  {"action": "skip_blind"}   -- only if skip tag is very valuable (free Joker) AND hand is weak

SELECTING_HAND  -- choose cards to play or discard:
  {"action": "play",    "hand_indices": [1,3,5]}   -- idx values from state hand[]
  {"action": "discard", "hand_indices": [2,4]}

ROUND_EVAL:
  {"action": "cash_out"}

SHOP:
  {"action": "buy",      "area": "joker",   "slot": 1}
  {"action": "buy",      "area": "voucher",  "slot": 1}
  {"action": "sell",     "joker_slot": 2}
  {"action": "reroll_shop"}
  {"action": "next_round"}    -- always end shop with this

MENU / GAME_OVER / SPLASH:
  {"action": "start_run"}

== HAND PRIORITY (best→worst) ==
Straight Flush > Four of a Kind > Full House > Flush > Straight >
Three of a Kind > Two Pair > Pair > High Card

== DISCARD RULE ==
Discard if ALL hold: discards_left >= 1, hands_left >= 2,
best hand is Pair or worse, hand has a 4-card flush/straight draw or 3oaK draw.
Keep the partial, drop outliers. Never discard all 5 speculatively.

== SHOP PRIORITY ==
Jokers > Planet cards > Tarot (situational) > Reroll (only if shop useless AND dollars > 8)
Skip boosters (can't open packs). Reserve $2 buffer after purchase.

Respond with raw JSON only."""

# ── chips-needed reference table (ante fallback) ─────────────────────────────
BLIND_CHIPS = {
    1: (300, 450, 600),
    2: (800, 1200, 1600),
    3: (2000, 3000, 4000),
    4: (5000, 7500, 10000),
    5: (11000, 16500, 22000),
    6: (20000, 30000, 40000),
    7: (35000, 52500, 70000),
    8: (50000, 75000, 100000),
}

KNOWN_ACTIONS = {"play", "discard", "select_blind", "skip_blind", "cash_out",
                 "buy", "sell", "reroll_shop", "next_round", "start_run",
                 "reroll_boss", "use_consumable"}


def blind_position(ante, round_abs):
    """Convert absolute round counter to blind index (0=Small,1=Big,2=Boss)."""
    return (round_abs - 1) % 3


def extract_states(log_dir, target_count):
    """
    Walk JSONL logs and pull representative SELECTING_HAND snapshots.
    Returns list of dicts: {seed, label, state, hand, note}
    """
    logs = sorted(glob.glob(os.path.join(log_dir, "*.jsonl")), key=os.path.getsize, reverse=True)
    if not logs:
        print(f"No JSONL logs found in {log_dir}")
        sys.exit(1)

    snapshots = []
    seen_labels = set()

    for log_path in logs:
        seed = Path(log_path).stem.split("_")[-1]
        events = []
        try:
            with open(log_path) as f:
                for line in f:
                    line = line.strip()
                    if line:
                        events.append(json.loads(line))
        except Exception as e:
            print(f"  skip {log_path}: {e}")
            continue

        # Collect HAND_PLAYED and CARDS_DISCARDED — both have state_before=SELECTING_HAND
        for ev in events:
            if ev.get("event") not in ("HAND_PLAYED", "CARDS_DISCARDED"):
                continue
            sb = ev.get("state_before", {})
            if sb.get("state") != "SELECTING_HAND":
                continue

            ante      = sb.get("ante", 1)
            round_abs = sb.get("round", 1)
            blind_idx = blind_position(ante, round_abs)
            blind_name = ["Small", "Big", "Boss"][blind_idx]

            # Phase label for diversity sampling
            phase = "early" if ante <= 2 else ("mid" if ante <= 5 else "late")
            label = f"{seed}_{phase}_a{ante}r{round_abs}"
            if label in seen_labels:
                continue
            seen_labels.add(label)

            # Reconstruct chips_needed
            chips_needed = sb.get("chips_needed", 0)
            if chips_needed == 0 and ante in BLIND_CHIPS:
                chips_needed = BLIND_CHIPS[ante][blind_idx]

            # Build hand from action.cards — assign idx 1-based
            raw_cards = ev.get("action", {}).get("cards", [])
            hand = [
                {"idx": i + 1, "suit": c.get("suit", "?"), "value": c.get("value", "?"), "nominal": c.get("nominal", 0)}
                for i, c in enumerate(raw_cards)
            ]

            state_snapshot = {
                "state":          "SELECTING_HAND",
                "ante":           ante,
                "round":          round_abs,
                "blind":          blind_name,
                "hands_left":     sb.get("hands_left", 4),
                "discards_left":  sb.get("discards_left", 3),
                "chips_scored":   sb.get("chips_scored", 0),
                "chips_needed":   chips_needed,
                "dollars":        sb.get("dollars", 4),
                "joker_count":    sb.get("joker_count", 0),
                "consumable_count": sb.get("consumable_count", 0),
                "hand":           hand,
                "jokers":         [],    # compact logs don't embed full joker list
                "shop":           {"jokers": [], "vouchers": [], "boosters": []},
            }

            snapshots.append({
                "seed":  seed,
                "label": label,
                "phase": phase,
                "state": state_snapshot,
                "note":  f"{ev['event']} seq={ev.get('seq','?')}",
            })

            if len(snapshots) >= target_count:
                break

        if len(snapshots) >= target_count:
            break

    return snapshots[:target_count]


def call_ollama(base_url, model, state_json, wiki_context="", timeout=60):
    """Call Ollama /api/chat, return (response_text, metrics_dict)."""
    import urllib.request
    user_content = f"Current game state:\n{json.dumps(state_json, indent=2)}"
    if wiki_context:
        user_content += f"\n\n== RELEVANT WIKI KNOWLEDGE ==\n{wiki_context}"
    user_content += "\n\nRespond with the action JSON only."
    payload = {
        "model":  model,
        "stream": False,
        "format": "json",
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user",   "content": user_content},
        ],
    }
    body = json.dumps(payload).encode()
    req  = urllib.request.Request(
        f"{base_url}/api/chat",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
        elapsed = time.perf_counter() - t0
        data    = json.loads(raw)
    except Exception as e:
        return None, {"error": str(e)}

    content = data.get("message", {}).get("content", "")
    # Ollama returns eval_count (tokens generated) and eval_duration (nanoseconds)
    eval_count    = data.get("eval_count", 0)
    eval_duration = data.get("eval_duration", 1)  # nanoseconds
    prompt_eval_duration = data.get("prompt_eval_duration", 0)

    toks_per_sec = eval_count / (eval_duration / 1e9) if eval_count else 0.0
    ttft = prompt_eval_duration / 1e9  # time to first token ≈ prompt eval time

    return content, {
        "elapsed_s":   round(elapsed, 2),
        "ttft_s":      round(ttft, 2),
        "toks_per_sec": round(toks_per_sec, 1),
        "eval_tokens": eval_count,
    }


def validate_action(text):
    """Return (action_str, is_valid) from model response text."""
    try:
        obj = json.loads(text.strip())
        action = obj.get("action", "")
        return action, action in KNOWN_ACTIONS
    except Exception:
        return "(parse error)", False


def print_table(results):
    cols = ["#", "Seed", "Phase", "Ante/Round", "Jokers", "Elapsed", "TTFT", "Tok/s", "Action", "Valid"]
    widths = [3, 10, 6, 10, 6, 8, 7, 7, 22, 6]

    def row(*vals):
        return "  ".join(str(v).ljust(w) for v, w in zip(vals, widths))

    print()
    print(row(*cols))
    print("  ".join("-" * w for w in widths))
    for i, r in enumerate(results, 1):
        m = r["metrics"]
        if "error" in m:
            elapsed = ttft = toks = "ERR"
        else:
            elapsed = f"{m['elapsed_s']}s"
            ttft    = f"{m['ttft_s']}s"
            toks    = f"{m['toks_per_sec']}"
        print(row(i, r["seed"][:10], r["phase"],
                  f"A{r['ante']}/R{r['round']}",
                  r["joker_count"],
                  elapsed, ttft, toks,
                  r["action"][:22], "YES" if r["valid"] else "NO"))

    # Summary stats
    good = [r for r in results if "error" not in r["metrics"]]
    if good:
        elapsed_vals = [r["metrics"]["elapsed_s"] for r in good]
        tok_vals     = [r["metrics"]["toks_per_sec"] for r in good]
        valid_count  = sum(1 for r in good if r["valid"])
        rag_vals     = [r["rag_ms"] for r in good if r.get("rag_ms", 0) > 0]
        print()
        print(f"  Runs: {len(results)}  |  Valid JSON actions: {valid_count}/{len(results)}")
        print(f"  Elapsed  — median: {sorted(elapsed_vals)[len(elapsed_vals)//2]}s  "
              f"min: {min(elapsed_vals)}s  max: {max(elapsed_vals)}s")
        print(f"  Tok/sec  — median: {sorted(tok_vals)[len(tok_vals)//2]}  "
              f"min: {min(tok_vals)}  max: {max(tok_vals)}")
        if rag_vals:
            print(f"  RAG ms   — median: {sorted(rag_vals)[len(rag_vals)//2]}ms  "
                  f"min: {min(rag_vals)}ms  max: {max(rag_vals)}ms")
        print()
        median_elapsed = sorted(elapsed_vals)[len(elapsed_vals) // 2]
        if median_elapsed > 5:
            print("  WARNING: median > 5s — consider qwen2.5:3b or phi3:mini for faster play")
        else:
            print("  Model is fast enough for live play (median <= 5s)")


def main():
    parser = argparse.ArgumentParser(description="Benchmark Ollama model for Balatro agent")
    parser.add_argument("--model",  default=DEFAULT_MODEL, help=f"Ollama model name (default: {DEFAULT_MODEL})")
    parser.add_argument("--url",    default=OLLAMA_BASE_URL, help="Ollama base URL")
    parser.add_argument("--states", type=int, default=NUM_STATES, help="Number of game states to test")
    parser.add_argument("--rag",    action="store_true", help="Include RAG retrieval overhead in benchmark (embed query + lancedb search)")
    parser.add_argument("--list-models", action="store_true", help="List available Ollama models and exit")
    args = parser.parse_args()

    import urllib.request
    if args.list_models:
        try:
            with urllib.request.urlopen(f"{args.url}/api/tags", timeout=5) as r:
                data = json.loads(r.read())
            for m in data.get("models", []):
                print(f"  {m['name']:30s}  {m['details']['parameter_size']}")
        except Exception as e:
            print(f"Cannot reach Ollama at {args.url}: {e}")
        return

    # Verify Ollama is up
    try:
        with urllib.request.urlopen(f"{args.url}/api/tags", timeout=5) as r:
            data = json.loads(r.read())
        model_names = [m["name"] for m in data.get("models", [])]
    except Exception as e:
        print(f"ERROR: Cannot reach Ollama at {args.url}: {e}")
        print("Run: docker start <ollama-container-id>")
        sys.exit(1)

    if args.model not in model_names:
        print(f"ERROR: Model '{args.model}' not found in Ollama.")
        print(f"Available: {', '.join(model_names)}")
        print(f"Pull with: docker exec ollama ollama pull {args.model}")
        sys.exit(1)

    rag = None
    if args.rag:
        try:
            from rag import RagIndex
            print("Initializing RAG index...")
            rag = RagIndex(ollama_url=args.url)
            print()
        except ImportError:
            print("WARNING: rag.py not found — running without RAG")
        except Exception as e:
            print(f"WARNING: RAG init failed ({e}) — running without RAG")

    print(f"Benchmarking model: {args.model}  ({args.url})"
          + ("  [+RAG]" if rag else ""))
    print(f"Extracting {args.states} game states from {LOG_DIR}...")

    snapshots = extract_states(LOG_DIR, args.states)
    if not snapshots:
        print("No SELECTING_HAND states found in logs.")
        sys.exit(1)

    print(f"Found {len(snapshots)} states. Running benchmark...\n")

    results = []
    for i, snap in enumerate(snapshots, 1):
        state = snap["state"]
        label = snap["label"]
        print(f"  [{i:2d}/{len(snapshots)}] {label}  (A{state['ante']}/R{state['round']}, "
              f"jokers={state['joker_count']}, hand={len(state['hand'])} cards) ... ", end="", flush=True)

        wiki_context = ""
        rag_ms = 0.0
        if rag:
            t_rag = time.perf_counter()
            try:
                wiki_context = rag.retrieve_for_state(state, top_k=4)
            except Exception as e:
                print(f"\n  RAG retrieve failed: {e}", end="")
            rag_ms = (time.perf_counter() - t_rag) * 1000

        response, metrics = call_ollama(args.url, args.model, state,
                                        wiki_context=wiki_context)

        if "error" in metrics:
            print(f"ERROR: {metrics['error']}")
            action, valid = "(error)", False
        else:
            action, valid = validate_action(response or "")
            rag_tag = f"  rag={rag_ms:.0f}ms" if rag else ""
            status = "OK" if valid else f"INVALID({response[:40] if response else 'empty'})"
            print(f"{metrics['elapsed_s']}s  {metrics['toks_per_sec']} tok/s{rag_tag}  → {action}  [{status}]")

        results.append({
            "seed":        snap["seed"],
            "phase":       snap["phase"],
            "ante":        state["ante"],
            "round":       state["round"],
            "joker_count": state["joker_count"],
            "action":      action,
            "valid":       valid,
            "metrics":     metrics,
            "rag_ms":      round(rag_ms),
        })

    print_table(results)


if __name__ == "__main__":
    main()
