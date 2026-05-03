#!/usr/bin/env python3
"""
Balatro autonomous agent — drives the game via Ollama local LLM.

Usage:
    python3 agent.py [--model MODEL] [--url URL]

Reads ~/balatro-logs/state.json, decides an action via Ollama,
writes ~/balatro-logs/command.json, waits for the game to consume it, repeats.
"""

import argparse
import json
import os
import sys
import time
import urllib.request
from datetime import datetime

# RAG is optional — agent works without it, just with less game knowledge
try:
    from rag import RagIndex
    _RAG_AVAILABLE = True
except ImportError:
    _RAG_AVAILABLE = False

# ── config ───────────────────────────────────────────────────────────────────
OLLAMA_BASE_URL = "http://localhost:11434"
DEFAULT_MODEL   = "qwen2.5:7b"
STATE_FILE      = os.path.expanduser("~/balatro-logs/state.json")
CMD_FILE        = os.path.expanduser("~/balatro-logs/command.json")
STATE_STALE_S   = 60    # warn if state.json hasn't changed in this many seconds
CMD_TIMEOUT_S   = 5     # max seconds to wait for game to consume command.json
POLL_INTERVAL_S = 0.5   # seconds between state polls in animation states

# ── states that need no action (animations — just wait) ──────────────────────
WAIT_STATES = {"SPLASH", "HAND_PLAYED", "DRAW_TO_HAND", "NEW_ROUND"}

# ── chips-needed reference table (fallback when state reports 0) ─────────────
BLIND_CHIPS = {
    1: (300, 450, 600),    2: (800, 1200, 1600),
    3: (2000, 3000, 4000), 4: (5000, 7500, 10000),
    5: (11000, 16500, 22000), 6: (20000, 30000, 40000),
    7: (35000, 52500, 70000), 8: (50000, 75000, 100000),
}

# ── system prompt (core rules only — game knowledge comes via RAG) ────────────
SYSTEM_PROMPT = """You are an AI playing Balatro, a roguelike poker card game.
Respond with EXACTLY one JSON action and nothing else — no explanation, no markdown.

== SCORING ==
Score = (base_chips + card_chips) × (base_mult + joker_mult) × x_mult_jokers
Hand base values: High Card 5×1, Pair 10×2, Two Pair 20×2, Three of Kind 30×3,
Straight 30×4, Flush 35×4, Full House 40×4, Four of Kind 60×7, Straight Flush 100×8.
Each scored card adds its nominal value to chips (Ace=11, face=10, others=face value).
Always play 5 cards to maximise chip contribution even on High Card hands.

== VALID ACTIONS BY STATE ==
BLIND_SELECT:  {"action":"select_blind"} | {"action":"skip_blind"}
SELECTING_HAND: {"action":"play","hand_indices":[1,2,3,4,5]} | {"action":"discard","hand_indices":[3,4]}
ROUND_EVAL:    {"action":"cash_out"}
SHOP:          {"action":"buy","area":"joker","slot":1} | {"action":"buy","area":"voucher","slot":1}
               {"action":"sell","joker_slot":2} | {"action":"reroll_shop"} | {"action":"next_round"}
MENU/GAME_OVER: {"action":"start_run"}

== HAND PRIORITY ==
Straight Flush > Four of a Kind > Full House > Flush > Straight > Three of a Kind > Two Pair > Pair > High Card

== DISCARD RULE ==
Discard ONLY if ALL: discards_left>=1, hands_left>=2, best hand is Pair or worse,
hand has a 4-card flush/straight draw OR 3-of-a-kind draw.
Keep the partial, drop outliers. Never discard all 5. On hands_left==1, always play.

== BLIND SELECT ==
Always select Small and Big blinds. Skip Boss only if skip tag gives a free Joker
AND your joker build is already strong.

== SHOP ==
Priority: Jokers (win condition) > Planet cards > Tarot (situational) > Reroll (only if useless shop AND $>8).
Skip boosters (can't open packs). Keep $2 buffer. End shop with next_round.

The wiki articles below contain detailed joker effects and synergies — use them.
Respond with raw JSON only."""

KNOWN_ACTIONS = {
    "play", "discard", "select_blind", "skip_blind", "cash_out",
    "buy", "sell", "reroll_shop", "next_round", "start_run",
    "reroll_boss", "use_consumable",
}


# ── helpers ───────────────────────────────────────────────────────────────────

def ts():
    return datetime.now().strftime("%H:%M:%S")

def log(msg):
    print(f"[{ts()}] {msg}", flush=True)

def read_state():
    """Read and parse state.json. Returns (state_dict, mtime) or (None, None)."""
    try:
        mtime = os.path.getmtime(STATE_FILE)
        with open(STATE_FILE) as f:
            return json.load(f), mtime
    except Exception:
        return None, None

def write_command(cmd):
    """Atomically write command.json."""
    tmp = CMD_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cmd, f)
    os.replace(tmp, CMD_FILE)

def command_pending():
    return os.path.exists(CMD_FILE)

def wait_command_consumed(timeout=CMD_TIMEOUT_S):
    """Block until command.json disappears (game consumed it). Returns True if consumed."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not command_pending():
            return True
        time.sleep(0.1)
    return False

def fix_chips_needed(state):
    """Fill in chips_needed from reference table if state reports 0."""
    if state.get("chips_needed", 0) == 0:
        ante = state.get("ante", 1)
        round_abs = state.get("round", 1)
        blind_idx = (round_abs - 1) % 3
        if ante in BLIND_CHIPS:
            state["chips_needed"] = BLIND_CHIPS[ante][blind_idx]
    return state

def summarize_state(state):
    """One-line human-readable state summary for logging."""
    s = state.get("state", "?")
    ante = state.get("ante", "?")
    rnd  = state.get("round", "?")
    hands = state.get("hands_left", "?")
    discards = state.get("discards_left", "?")
    scored = state.get("chips_scored", 0)
    needed = state.get("chips_needed", 0)
    dollars = state.get("dollars", "?")
    jokers = state.get("joker_count", 0)
    hand = state.get("hand", [])
    hand_str = " ".join(f"{c.get('value','?')}{c.get('suit','?')[0]}" for c in hand if "value" in c)
    return (f"{s}  A{ante}/R{rnd}  hands={hands} disc={discards}  "
            f"{scored}/{needed} chips  ${dollars}  jokers={jokers}"
            + (f"  hand=[{hand_str}]" if hand_str else ""))


# ── Ollama call ───────────────────────────────────────────────────────────────

def ask_ollama(base_url, model, state, wiki_context="", timeout=30):
    """Send state (+ optional wiki context) to Ollama, return parsed action or None."""
    user_content = f"Current game state:\n{json.dumps(state, indent=2)}"
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
        log(f"  Ollama error: {e}")
        return None, 0.0

    content = data.get("message", {}).get("content", "")
    eval_count    = data.get("eval_count", 0)
    eval_duration = data.get("eval_duration", 1)
    toks_per_sec  = eval_count / (eval_duration / 1e9) if eval_count else 0.0

    try:
        action = json.loads(content.strip())
    except Exception:
        log(f"  Model returned non-JSON: {content[:80]}")
        return None, elapsed

    if action.get("action") not in KNOWN_ACTIONS:
        log(f"  Unknown action '{action.get('action')}' — skipping")
        return None, elapsed

    log(f"  → {json.dumps(action)}  ({elapsed:.2f}s  {toks_per_sec:.0f} tok/s)")
    return action, elapsed


# ── main loop ─────────────────────────────────────────────────────────────────

def run_agent(base_url, model, no_rag=False):
    log(f"Agent starting — model: {model}  url: {base_url}")
    log(f"State file : {STATE_FILE}")
    log(f"Command file: {CMD_FILE}")

    # Verify Ollama is reachable and model exists
    try:
        with urllib.request.urlopen(f"{base_url}/api/tags", timeout=5) as r:
            tags = json.loads(r.read())
        available = [m["name"] for m in tags.get("models", [])]
    except Exception as e:
        log(f"ERROR: Cannot reach Ollama at {base_url}: {e}")
        sys.exit(1)

    if model not in available:
        log(f"ERROR: Model '{model}' not in Ollama. Available: {', '.join(available)}")
        log(f"Pull it with: ollama pull {model}")
        sys.exit(1)

    log(f"Ollama OK. Model '{model}' ready. Watching for game state...\n")

    # Init RAG index
    rag = None
    if not no_rag and _RAG_AVAILABLE:
        try:
            rag = RagIndex(ollama_url=base_url)
        except Exception as e:
            log(f"RAG init failed (will play without wiki context): {e}")
    elif not _RAG_AVAILABLE and not no_rag:
        log("rag.py not found — playing without wiki context")

    # Warm up the model (avoid 15s cold-start on first real decision)
    log("Warming up model (pre-loading into GPU memory)...")
    _warmup_payload = {
        "model": model, "stream": False, "format": "json",
        "messages": [{"role": "user", "content": "Reply with {\"ready\":true}"}],
    }
    try:
        req = urllib.request.Request(f"{base_url}/api/chat",
                                     data=json.dumps(_warmup_payload).encode(),
                                     headers={"Content-Type": "application/json"},
                                     method="POST")
        with urllib.request.urlopen(req, timeout=30):
            pass
        log("Model warm.\n")
    except Exception as e:
        log(f"Warmup failed (non-fatal): {e}\n")

    last_state_str = None
    last_mtime     = None
    consecutive_wait = 0

    while True:
        # ── clear any stale command that we may have left ──────────────────
        if command_pending():
            log("WARNING: stale command.json found — removing before next action")
            try:
                os.remove(CMD_FILE)
            except Exception:
                pass

        state, mtime = read_state()

        if state is None:
            log("state.json not found or unreadable — is the game running?")
            time.sleep(2)
            continue

        # Warn if state hasn't updated in a while
        if last_mtime and (mtime - last_mtime) == 0:
            age = time.time() - mtime
            if age > STATE_STALE_S:
                log(f"WARNING: state.json is {age:.0f}s old — game may be stuck or closed")

        current_state_name = state.get("state", "")

        # ── animation / transitional states — just wait ────────────────────
        if current_state_name in WAIT_STATES:
            consecutive_wait += 1
            if consecutive_wait == 1:
                log(f"Waiting ({current_state_name})...")
            time.sleep(POLL_INTERVAL_S)
            last_mtime = mtime
            continue
        consecutive_wait = 0

        # ── skip if state hasn't changed since last action ─────────────────
        state_str = json.dumps(state, sort_keys=True)
        if state_str == last_state_str:
            time.sleep(POLL_INTERVAL_S)
            continue
        last_state_str = state_str
        last_mtime     = mtime

        # ── GAME_OVER — ask user ───────────────────────────────────────────
        if current_state_name == "GAME_OVER":
            ante   = state.get("ante", "?")
            rnd    = state.get("round", "?")
            jokers = [j.get("name", j.get("key", "?")) for j in state.get("jokers", [])]
            log(f"\nGAME OVER — reached Ante {ante} Round {rnd}")
            log(f"Final jokers: {jokers or 'none'}")
            print("\nStart a new run? [y/N] ", end="", flush=True)
            try:
                answer = input().strip().lower()
            except (EOFError, KeyboardInterrupt):
                answer = "n"
            if answer == "y":
                log("Starting new run...")
                write_command({"action": "start_run"})
                wait_command_consumed()
                last_state_str = None
            else:
                log("Exiting agent.")
                break
            continue

        # ── patch chips_needed if needed ───────────────────────────────────
        state = fix_chips_needed(state)

        # ── log current state ──────────────────────────────────────────────
        log(summarize_state(state))

        # ── retrieve relevant wiki context via RAG ─────────────────────────
        wiki_context = ""
        if rag:
            try:
                wiki_context = rag.retrieve_for_state(state, top_k=4)
                if wiki_context:
                    titles = [l.split("]")[-1].split("\n")[0].strip()
                              for l in wiki_context.split("### [") if "]" in l]
                    log(f"  Wiki: {', '.join(t for t in titles if t)}")
            except Exception as e:
                log(f"  RAG retrieve failed: {e}")

        # ── ask the model ──────────────────────────────────────────────────
        action, _ = ask_ollama(base_url, model, state, wiki_context=wiki_context)
        if action is None:
            log("  No valid action returned — retrying next poll")
            time.sleep(1)
            last_state_str = None  # force re-ask on next loop
            continue

        # ── write command and wait for consumption ─────────────────────────
        write_command(action)
        consumed = wait_command_consumed()
        if not consumed:
            log(f"  WARNING: command.json not consumed after {CMD_TIMEOUT_S}s — game may be stuck")

        time.sleep(POLL_INTERVAL_S)


def main():
    parser = argparse.ArgumentParser(description="Balatro autonomous Ollama agent")
    parser.add_argument("--model",   default=DEFAULT_MODEL,
                        help=f"Ollama model name (default: {DEFAULT_MODEL})")
    parser.add_argument("--url",     default=OLLAMA_BASE_URL,
                        help=f"Ollama base URL (default: {OLLAMA_BASE_URL})")
    parser.add_argument("--no-rag",  action="store_true",
                        help="Disable RAG wiki context (faster but dumber)")
    args = parser.parse_args()

    try:
        run_agent(args.url, args.model, no_rag=args.no_rag)
    except KeyboardInterrupt:
        print("\nAgent stopped.")


if __name__ == "__main__":
    main()
