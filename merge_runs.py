#!/usr/bin/env python3
"""
Migrate old-format Balatro log files to the new format.

Old format: seed_<SEED>_<N>.jsonl / .txt  (counter suffix, unreadable txt)
New format: YYYYMMDD_HHMMSS_<SEED>.jsonl / .txt  (timestamp prefix, readable txt)

For each seed, files are sorted by counter and chained:
- If a file's RUN_START has state_after.ante > 1 → continuation, merge into previous
- Otherwise → fresh run, becomes its own file

The txt is regenerated from the JSONL (new readable format).
Originals are deleted only after confirmation.

Usage:
    python merge_runs.py [--dry-run]
"""

import json
import os
import re
import sys
import datetime
from collections import defaultdict

LOG_DIR = os.path.expanduser("~/balatro-logs")
DRY_RUN = "--dry-run" in sys.argv

# ─────────────────────────────────────────────────────────────
# TXT regeneration (mirrors recorder.lua formatting logic)
# ─────────────────────────────────────────────────────────────

SUIT_SYM = {"Hearts": "♥", "Diamonds": "♦", "Clubs": "♣", "Spades": "♠"}
VAL_ABR  = {
    "Ace": "A", "2": "2", "3": "3", "4": "4", "5": "5",
    "6": "6",   "7": "7", "8": "8", "9": "9", "10": "10",
    "Jack": "J", "Queen": "Q", "King": "K",
}

def num(n):
    if n is None: return "?"
    try:    return f"{int(n):,}"
    except: return str(n)

def cstr(c):
    if not isinstance(c, dict): return "?"
    v = VAL_ABR.get(str(c.get("value", "")), str(c.get("value", "?"))[:2])
    s = SUIT_SYM.get(c.get("suit", ""), str(c.get("suit", "?"))[:1])
    return v + s

def clist(cards):
    if not cards: return ""
    return " ".join(cstr(c) for c in cards if isinstance(c, dict))

def kname(key):
    if not key: return "?"
    name = re.sub(r'^[cjvpbe]_', '', str(key)).replace('_', ' ')
    return ' '.join(w.capitalize() for w in name.split())

def pack_name(key):
    if not key: return "Pack"
    m = re.match(r'^p_(\w+?)_(normal|mega)_', str(key))
    if not m: return kname(key)
    ptype = m.group(1).capitalize() + " Pack"
    return ("Mega " + ptype) if m.group(2) == "mega" else ptype

SUPPRESS = {
    "STATE_CHANGE", "HAND_DEALT", "ROUND_RESOURCES", "CONSUMABLE_SNAPSHOT",
    "DECK_SNAPSHOT", "SHOP_CLOSED", "JOKER_GRAPH", "HAND_LEVELS", "DECK_CHANGE",
    "BLIND_OPTIONS", "BOSS_REROLL", "MONEY_CHANGE", "RUN_START",
}

def fmt_event(ev, ts_str):
    e  = ev.get("event", "")
    a  = ev.get("action")  if isinstance(ev.get("action"),     dict) else {}
    r  = ev.get("resolution") if isinstance(ev.get("resolution"), dict) else {}
    sb = ev.get("state_before") if isinstance(ev.get("state_before"), dict) else {}
    sa = ev.get("state_after")  if isinstance(ev.get("state_after"),  dict) else {}

    if e in SUPPRESS:
        return None

    if e == "ROUND_START":
        ante  = sb.get("ante", "?"); rnd = sb.get("round", "?")
        bname = r.get("blind_name", "?"); chips = r.get("chips_needed")
        btype = "boss" if r.get("boss") else (
            "small" if a.get("blind_key") == "bl_small" else "big")
        return f"\n── Ante {ante}, Round {rnd} ── {bname} ({btype}, {num(chips)} chips needed) ──"

    if e == "BOSS_BLIND_ACTIVE":
        return f"  ⚡ Boss: {r.get('name', '?')}"

    if e == "BLIND_SKIPPED":
        tags = [kname(t) for t in (r.get("tags_earned") or [])]
        tag_str = f"  [tags: {', '.join(tags)}]" if tags else ""
        return f"  Skipped blind{tag_str}"

    if e == "HAND_PLAYED":
        s = clist(a.get("cards", []))
        return f"  ► {s}" if s else None

    if e == "HAND_RESOLUTION":
        ht    = r.get("hand_type", "?")
        score = r.get("final_score", 0)
        total = sa.get("chips_scored", 0)
        need  = sb.get("chips_needed", 0)
        won   = need > 0 and total >= need
        return f"    → {ht}  {num(score)} pts  ({num(total)} / {num(need)})" + (" ✓" if won else "")

    if e == "CARDS_DISCARDED":
        s = clist(a.get("cards", []))
        return f"  Discarded: {s}" if s else None

    if e == "SHOP_INVENTORY":
        if (a.get("reroll_number") or 0) > 0: return None
        return f"\n── Shop (${sb.get('dollars', '?')}) ──"

    if e == "SHOP_BUY":
        item = a.get("item") if isinstance(a.get("item"), dict) else {}
        name = item.get("name") or kname(a.get("item_key"))
        return f"  Bought: {name}  -${r.get('cost', '?')}"

    if e == "SHOP_SELL":
        item = a.get("item") if isinstance(a.get("item"), dict) else {}
        name = item.get("name") or kname(a.get("item_key"))
        return f"  Sold: {name}  +${r.get('sell_price', '?')}"

    if e == "SHOP_REROLL":
        return f"  Rerolled  -${a.get('reroll_cost', '?')}"

    if e == "PACK_OPENED":
        took = kname(a.get("selected")) if a.get("selected") else "nothing"
        return f"  Pack: {pack_name(a.get('pack_key'))}  → {took}"

    if e == "CONSUMABLE_USED":
        item = a.get("item") if isinstance(a.get("item"), dict) else {}
        name = item.get("name") or kname(a.get("item_key"))
        tgts = clist(a.get("targets") or [])
        return f"  Used: {name}" + (f"  on [{tgts}]" if tgts else "")

    if e == "GAME_OVER":
        return (f"\n✗ GAME OVER — Ante {r.get('ante', sb.get('ante', '?'))}, "
                f"Round {r.get('round', sb.get('round', '?'))} — ${sb.get('dollars', '?')}")

    if e == "GAME_WIN":
        return f"\n✓ WIN — Ante {r.get('ante', '?')}, Round {r.get('round', '?')} — ${r.get('dollars', '?')}"

    return None  # unknown events: suppress


def regenerate_txt(seed, sessions):
    """
    sessions: list of (jsonl_path, is_continuation, timestamp_str)
    Returns the full txt content as a string.
    """
    first = True
    out = []
    for jsonl_path, is_continuation, ts_str in sessions:
        if first:
            out.append("=== BALATRO RUN RECORDER ===")
            out.append(f"Seed:  {seed}")
            out.append(f"Time:  {ts_str}")
            out.append("=" * 40)
            out.append("")
            first = False
        else:
            out.append("")
            out.append("─" * 44)
            out.append(f"── RESUMED: {ts_str} ──")
            out.append("─" * 44)
            out.append("")

        with open(jsonl_path) as f:
            for line in f:
                line = line.strip()
                if not line: continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                # Use timestamp from event
                raw_ts = ev.get("ts")
                if raw_ts:
                    dt = datetime.datetime.fromtimestamp(raw_ts)
                    hms = dt.strftime("%H:%M:%S")
                else:
                    hms = "??:??:??"
                line_str = fmt_event(ev, hms)
                if line_str is not None:
                    out.append(f"[{hms}] {line_str}" if not line_str.startswith("\n") else line_str)

    return "\n".join(out) + "\n"


# ─────────────────────────────────────────────────────────────
# File discovery and grouping
# ─────────────────────────────────────────────────────────────

def get_run_start_ante(jsonl_path):
    """Read just the RUN_START event and return state_after.ante."""
    with open(jsonl_path) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                ev = json.loads(line)
                if ev.get("event") == "RUN_START":
                    sa = ev.get("state_after") if isinstance(ev.get("state_after"), dict) else {}
                    return sa.get("ante", 1)
            except json.JSONDecodeError:
                continue
    return 1


def find_old_files():
    """Return dict: seed → sorted list of (n, jsonl_path, txt_path)"""
    pattern = re.compile(r'^seed_(.+)_(\d+)\.jsonl$')
    groups = defaultdict(list)
    for fname in os.listdir(LOG_DIR):
        m = pattern.match(fname)
        if not m: continue
        seed = m.group(1)
        n    = int(m.group(2))
        jsonl = os.path.join(LOG_DIR, fname)
        txt   = jsonl.replace(".jsonl", ".txt")
        if os.path.exists(txt):
            groups[seed].append((n, jsonl, txt))
    for seed in groups:
        groups[seed].sort(key=lambda x: x[0])
    return dict(groups)


def build_merge_chains(seed, files):
    """
    files: sorted list of (n, jsonl, txt)
    Returns list of chains, each chain is list of (jsonl, txt, mtime, ts_str, is_continuation)
    """
    chains = []
    current = []
    for n, jsonl, txt in files:
        ante = get_run_start_ante(jsonl)
        mtime = os.path.getmtime(jsonl)
        ts_str = datetime.datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M:%S")
        is_cont = (ante > 1) and len(current) > 0
        if not is_cont and current:
            chains.append(current)
            current = []
        current.append((jsonl, txt, mtime, ts_str, is_cont))
    if current:
        chains.append(current)
    return chains


# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────

def main():
    old_files = find_old_files()
    if not old_files:
        print("No old-format files found (seed_*_N.jsonl) in", LOG_DIR)
        return

    # Build the migration plan
    plan = []  # list of (output_base, chains_list, all_originals)
    for seed, files in sorted(old_files.items()):
        chains = build_merge_chains(seed, files)
        for chain in chains:
            first_mtime = chain[0][2]
            ts_prefix   = datetime.datetime.fromtimestamp(first_mtime).strftime("%Y%m%d_%H%M%S")
            output_base = os.path.join(LOG_DIR, f"{ts_prefix}_{seed}")
            originals   = [(j, t) for j, t, *_ in chain]
            plan.append((output_base, seed, chain, originals))

    # Print preview
    print(f"Found {sum(len(f) for f in old_files.values())} old file pairs across {len(old_files)} seed(s).\n")
    for output_base, seed, chain, originals in plan:
        print(f"  Seed: {seed}")
        for jsonl, txt, mtime, ts_str, is_cont in chain:
            label = "  continuation" if is_cont else "  fresh start"
            ante  = get_run_start_ante(jsonl)
            print(f"    [{label}] {os.path.basename(jsonl)}  (ante={ante} at RUN_START)")
        out_name = os.path.basename(output_base)
        print(f"    → {out_name}.jsonl + .txt  (merged, clean txt regenerated)")
        print()

    if DRY_RUN:
        print("Dry run — no files written or deleted.")
        return

    print("This will:")
    print("  1. Write merged files in the new format")
    print("  2. Delete the original old-format files")
    print()
    confirm = input("Proceed? (y/N) ").strip().lower()
    if confirm != "y":
        print("Aborted.")
        return

    for output_base, seed, chain, originals in plan:
        print(f"\nProcessing seed {seed}...")

        # 1. Merge JSONL (concatenate)
        out_jsonl = output_base + ".jsonl"
        with open(out_jsonl, "w") as out:
            for jsonl, txt, mtime, ts_str, is_cont in chain:
                with open(jsonl) as inp:
                    for line in inp:
                        out.write(line)

        # 2. Regenerate TXT
        sessions = [(j, is_cont, ts_str) for j, t, mtime, ts_str, is_cont in chain]
        txt_content = regenerate_txt(seed, sessions)
        out_txt = output_base + ".txt"
        with open(out_txt, "w") as out:
            out.write(txt_content)

        # 3. Delete originals
        for jsonl, txt in originals:
            os.remove(jsonl)
            if os.path.exists(txt):
                os.remove(txt)
            print(f"  Deleted {os.path.basename(jsonl)} + .txt")

        print(f"  Created {os.path.basename(out_jsonl)} + .txt")

    print("\nDone.")


if __name__ == "__main__":
    main()
