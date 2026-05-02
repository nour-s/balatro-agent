#!/usr/bin/env python3
"""Balatro run analyzer — feeds a recorded run log into Claude for coaching analysis.

Usage:
    python analyze_run.py                    # most recent run
    python analyze_run.py seed_U914N22W_2    # specific run by name
"""

import anthropic
import json
import os
import sys
import glob

LOG_DIR = os.path.expanduser("~/balatro-logs")


def find_run(name=None):
    if name:
        # Accept either an exact base name or just the seed (glob for newest match)
        exact_txt = os.path.join(LOG_DIR, name + ".txt")
        if os.path.exists(exact_txt):
            jsonl = exact_txt.replace(".txt", ".jsonl")
            if not os.path.exists(jsonl):
                sys.exit(f"Error: matching .jsonl not found for {exact_txt}")
            return exact_txt, jsonl
        # Glob for *_<name>.txt to support bare seed names like "U914N22W"
        matches = glob.glob(os.path.join(LOG_DIR, f"*_{name}.txt"))
        if not matches:
            sys.exit(f"Error: no log found for '{name}' in {LOG_DIR}")
        txt = max(matches, key=os.path.getmtime)
        jsonl = txt.replace(".txt", ".jsonl")
        if not os.path.exists(jsonl):
            sys.exit(f"Error: matching .jsonl not found for {txt}")
        return txt, jsonl

    txt_files = glob.glob(os.path.join(LOG_DIR, "*.txt"))
    if not txt_files:
        sys.exit(f"Error: no .txt files found in {LOG_DIR}")
    txt = max(txt_files, key=os.path.getmtime)
    jsonl = txt.replace(".txt", ".jsonl")
    if not os.path.exists(jsonl):
        sys.exit(f"Error: matching .jsonl not found for {txt}")
    return txt, jsonl


def extract_jsonl_stats(jsonl_path):
    stats = {
        "seed": None,
        "stake": None,
        "final_joker_keys": set(),
        "sold_joker_keys": set(),
        "key_to_name": {},
        "last_ante": None,
        "last_round": None,
        "chips_scored": None,
        "chips_needed": None,
        "game_over": False,
        "boss_blind": None,
    }

    with open(jsonl_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue

            event = ev.get("event", "")
            action = ev.get("action", {}) if isinstance(ev.get("action"), dict) else {}
            resolution = ev.get("resolution", {}) if isinstance(ev.get("resolution"), dict) else {}
            state_after = ev.get("state_after", {}) if isinstance(ev.get("state_after"), dict) else {}
            state_before = ev.get("state_before", {}) if isinstance(ev.get("state_before"), dict) else {}

            if event == "RUN_START":
                stats["seed"] = action.get("seed")
                stats["stake"] = action.get("stake")

            elif event == "SHOP_INVENTORY":
                for slot in resolution.get("slots", []):
                    if isinstance(slot, dict) and slot.get("set") == "Joker":
                        key = slot.get("key")
                        name = slot.get("name")
                        if key and name:
                            stats["key_to_name"][key] = name

            elif event == "SHOP_SELL":
                item = action.get("item", {}) if isinstance(action.get("item"), dict) else {}
                key = item.get("key") or action.get("item_key")
                name = item.get("name")
                if key:
                    stats["sold_joker_keys"].add(key)
                    if name:
                        stats["key_to_name"][key] = name

            elif event == "HAND_RESOLUTION":
                if isinstance(resolution, dict):
                    for j in resolution.get("joker_chain", []):
                        src = j.get("source")
                        if src:
                            stats["final_joker_keys"].add(src)
                ante = state_before.get("ante")
                rnd = state_before.get("round")
                if ante is not None:
                    stats["last_ante"] = ante
                    stats["last_round"] = rnd
                    stats["chips_scored"] = state_after.get("chips_scored", state_before.get("chips_scored"))
                    stats["chips_needed"] = state_before.get("chips_needed")

            elif event == "ROUND_START":
                stats["boss_blind"] = resolution.get("blind_name")

            elif event == "STATE_CHANGE":
                if state_after.get("state") == "GAME_OVER":
                    stats["game_over"] = True
                    if state_before.get("ante"):
                        stats["last_ante"] = state_before.get("ante")
                        stats["last_round"] = state_before.get("round")

    def key_to_display(k):
        if k in stats["key_to_name"]:
            return stats["key_to_name"][k]
        # j_vampire → "Vampire", j_green_joker → "Green Joker"
        return k.removeprefix("j_").replace("_", " ").title()

    active_keys = stats["final_joker_keys"] - stats["sold_joker_keys"]
    stats["final_jokers"] = [key_to_display(k) for k in sorted(active_keys)]

    return stats


def build_prompt(txt_content, stats, run_name):
    jokers = ", ".join(stats["final_jokers"]) if stats["final_jokers"] else "unknown (not captured in joker_chain)"

    outcome = "LOST" if stats["game_over"] else "unknown outcome"
    ante = stats.get("last_ante", "?")
    round_num = stats.get("last_round", "?")
    boss = stats.get("boss_blind")
    boss_line = f" (boss: {boss})" if boss else ""

    chips_scored = stats.get("chips_scored")
    chips_needed = stats.get("chips_needed")
    if chips_scored is not None and chips_needed is not None:
        deficit = chips_needed - chips_scored
        chips_line = f"Final total scored: {chips_scored:,} vs {chips_needed:,} needed (deficit: {deficit:,})"
    else:
        chips_line = "Final chip counts: not captured"

    stake_labels = {1: "White (1)", 2: "Red (2)", 3: "Green (3)", 4: "Black (4)",
                    5: "Blue (5)", 6: "Purple (6)", 7: "Orange (7)", 8: "Gold (8)"}
    stake_str = stake_labels.get(stats.get("stake"), str(stats.get("stake", "?")))

    stats_block = f"""## Run Summary
- Run: {run_name}
- Seed: {stats.get('seed', '?')}
- Stake: {stake_str}
- Outcome: {outcome} at Ante {ante}, Round {round_num}{boss_line}
- Active jokers at death (from joker_chain): {jokers}
- {chips_line}"""

    analysis_request = """## Analysis Request
You are a Balatro expert coach. Based on the run summary above and the full event timeline below, please analyze:

1. **Why the run ended** — what was the exact shortfall? Was it a chips problem, a mult problem, both, or something else (economy, boss blind, deck thinning)?
2. **Top 2-3 strategic mistakes** — be specific: cite events, hand types, buying/selling decisions, or missed opportunities from the log.
3. **What was missing** — which jokers, tarot cards, or synergies would have saved this build, and why?
4. **Next time** — one or two concrete prioritization changes the player should make from the early game onward.

Be direct. Reference actual events from the timeline (timestamps, hand types, totals)."""

    return f"""{stats_block}

{analysis_request}

## Full Run Timeline

{txt_content}"""


def main():
    run_name_arg = sys.argv[1] if len(sys.argv) > 1 else None
    txt_path, jsonl_path = find_run(run_name_arg)

    run_name = os.path.basename(txt_path).replace(".txt", "")
    print(f"Analyzing run: {run_name}", file=sys.stderr)

    stats = extract_jsonl_stats(jsonl_path)
    txt_content = open(txt_path).read()
    prompt = build_prompt(txt_content, stats, run_name)

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        sys.exit("Error: ANTHROPIC_API_KEY environment variable is not set")

    client = anthropic.Anthropic(api_key=api_key)

    print("\n--- Balatro Coach Analysis ---\n", flush=True)

    with client.messages.stream(
        model="claude-sonnet-4-6",
        max_tokens=2048,
        messages=[
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": prompt,
                        "cache_control": {"type": "ephemeral"},
                    }
                ],
            }
        ],
    ) as stream:
        for text in stream.text_stream:
            print(text, end="", flush=True)

    print("\n")


if __name__ == "__main__":
    main()
