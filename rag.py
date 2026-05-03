#!/usr/bin/env python3
"""
Balatro RAG module — embed wiki files with nomic-embed-text, store in lancedb,
retrieve relevant articles at decision time.

Usage as a script:
    python3 rag.py --build                    # index all wiki/ files
    python3 rag.py --query "Blueprint joker"  # test retrieval

Usage as a module:
    from rag import RagIndex
    rag = RagIndex()
    context = rag.retrieve(state_dict, top_k=5)
"""

import argparse
import glob
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

WIKI_DIR    = Path(__file__).parent / "wiki"
VECTOR_DIR  = Path(__file__).parent / "vectors"
OLLAMA_URL  = "http://localhost:11434"
EMBED_MODEL = "nomic-embed-text"
TABLE_NAME  = "wiki"


# ── embedding ─────────────────────────────────────────────────────────────────

def embed(text, ollama_url=OLLAMA_URL):
    """Return a 768-dim embedding vector for text via nomic-embed-text."""
    payload = json.dumps({"model": EMBED_MODEL, "prompt": text}).encode()
    req = urllib.request.Request(
        f"{ollama_url}/api/embeddings",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["embedding"]


# ── index building ────────────────────────────────────────────────────────────

def _entity_type(path):
    """Infer entity type from directory name."""
    parts = Path(path).parts
    for part in parts:
        if part in ("jokers", "tarot", "planet", "spectral", "voucher", "blind", "mechanic"):
            return part
    return "other"


def build_index(wiki_dir=WIKI_DIR, vector_dir=VECTOR_DIR, ollama_url=OLLAMA_URL, force=False):
    """
    Walk wiki_dir, embed each .md file, store in lancedb.
    Skips files already indexed unless force=True.
    Returns number of documents indexed.
    """
    import lancedb

    wiki_dir   = Path(wiki_dir)
    vector_dir = Path(vector_dir)
    vector_dir.mkdir(parents=True, exist_ok=True)

    db = lancedb.connect(str(vector_dir))

    # Load existing table to check what's already indexed
    existing_paths = set()
    if TABLE_NAME in db.table_names() and not force:
        tbl = db.open_table(TABLE_NAME)
        existing_paths = set(tbl.to_pandas()["path"].tolist())

    md_files = sorted(glob.glob(str(wiki_dir / "**" / "*.md"), recursive=True))
    if not md_files:
        print(f"No .md files found in {wiki_dir}")
        return 0

    to_index = [f for f in md_files if f not in existing_paths] if not force else md_files
    if not to_index:
        print(f"All {len(md_files)} files already indexed. Use --force to re-embed.")
        return 0

    print(f"Embedding {len(to_index)}/{len(md_files)} files with {EMBED_MODEL}...")
    rows = []
    for i, path in enumerate(to_index, 1):
        content = Path(path).read_text(encoding="utf-8").strip()
        name = Path(path).stem.replace("_", " ").title()

        # Use first heading as name if available
        for line in content.splitlines():
            if line.startswith("# "):
                name = line[2:].strip()
                break

        etype = _entity_type(path)

        try:
            vector = embed(content[:2000], ollama_url)  # cap at 2000 chars for embedding
        except Exception as e:
            print(f"  [{i:3d}] SKIP {path}: {e}")
            continue

        rows.append({
            "name":    name,
            "path":    path,
            "type":    etype,
            "content": content,
            "vector":  vector,
        })

        if i % 10 == 0 or i == len(to_index):
            print(f"  [{i:3d}/{len(to_index)}] embedded {name[:40]}")

    if not rows:
        return 0

    if TABLE_NAME in db.table_names() and not force:
        tbl = db.open_table(TABLE_NAME)
        tbl.add(rows)
    else:
        db.create_table(TABLE_NAME, rows, mode="overwrite")

    print(f"Indexed {len(rows)} documents → {vector_dir}")
    return len(rows)


# ── retrieval ─────────────────────────────────────────────────────────────────

class RagIndex:
    """
    Persistent RAG index. Open once at agent startup, call retrieve() per turn.
    Builds the index automatically on first use if it doesn't exist.
    """

    def __init__(self, wiki_dir=WIKI_DIR, vector_dir=VECTOR_DIR, ollama_url=OLLAMA_URL):
        import lancedb
        self.ollama_url = ollama_url
        self.vector_dir = Path(vector_dir)
        self.wiki_dir   = Path(wiki_dir)
        self._tbl = None

        db = lancedb.connect(str(self.vector_dir))
        if TABLE_NAME not in db.table_names():
            print("RAG index not found — building now (one-time, ~2 min)...")
            build_index(wiki_dir, vector_dir, ollama_url)

        db = lancedb.connect(str(self.vector_dir))  # re-open after possible build
        self._tbl = db.open_table(TABLE_NAME)
        count = self._tbl.count_rows()
        print(f"RAG ready: {count} documents indexed.")

    def retrieve(self, query_text, top_k=5):
        """
        Embed query_text, find top_k most relevant wiki articles,
        return a formatted markdown string ready to inject into a prompt.
        """
        try:
            q_vec = embed(query_text, self.ollama_url)
        except Exception as e:
            return f"(RAG unavailable: {e})"

        results = (
            self._tbl.search(q_vec)
            .limit(top_k)
            .select(["name", "type", "content"])
            .to_list()
        )

        if not results:
            return ""

        parts = []
        for r in results:
            parts.append(f"### [{r['type'].upper()}] {r['name']}\n{r['content'][:600]}")

        return "\n\n".join(parts)

    def retrieve_for_state(self, state, top_k=5):
        """
        Build a natural-language query from game state dict,
        then retrieve relevant wiki articles.
        """
        query = _state_to_query(state)
        return self.retrieve(query, top_k=top_k)


def _state_to_query(state):
    """Convert a game state dict into a semantic search query."""
    parts = []

    game_state = state.get("state", "")
    ante = state.get("ante", 1)
    round_abs = state.get("round", 1)
    blind_idx = (round_abs - 1) % 3
    blind_name = ["Small", "Big", "Boss"][blind_idx]
    parts.append(f"Ante {ante} {blind_name} blind")

    jokers = state.get("jokers", [])
    if jokers:
        names = [j.get("name", j.get("key", "")) for j in jokers]
        parts.append(f"jokers in play: {', '.join(names)}")

    hand = state.get("hand", [])
    if hand:
        suits = [c.get("suit", "") for c in hand if "suit" in c]
        values = [c.get("value", "") for c in hand if "value" in c]
        parts.append(f"hand cards: {' '.join(values)} suits: {' '.join(suits)}")

    shop = state.get("shop", {})
    shop_jokers = shop.get("jokers", [])
    if shop_jokers:
        names = [j.get("name", j.get("key", "")) for j in shop_jokers]
        parts.append(f"shop jokers available: {', '.join(names)}")

    consumables = state.get("consumables", [])
    if consumables:
        names = [c.get("name", c.get("key", "")) for c in consumables]
        parts.append(f"consumables: {', '.join(names)}")

    if game_state == "MENU":
        return "starting a new Balatro run, deck selection, stake, seed"
    elif game_state == "BLIND_SELECT":
        parts.append("selecting blind, deciding whether to skip or select")
    elif game_state == "SELECTING_HAND":
        chips_needed = state.get("chips_needed", 0)
        chips_scored = state.get("chips_scored", 0)
        hands_left = state.get("hands_left", 4)
        discards_left = state.get("discards_left", 3)
        parts.append(f"need {chips_needed - chips_scored} more chips, {hands_left} hands {discards_left} discards left")
        parts.append("deciding which cards to play or discard")
    elif game_state == "SHOP":
        parts.append("in shop deciding what to buy, sell or skip")

    return ". ".join(parts)


# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Balatro RAG index tool")
    parser.add_argument("--build",  action="store_true", help="Build/rebuild the vector index")
    parser.add_argument("--force",  action="store_true", help="Re-embed all files even if indexed")
    parser.add_argument("--query",  type=str,            help="Test a retrieval query")
    parser.add_argument("--top-k",  type=int, default=5, help="Number of results to retrieve")
    args = parser.parse_args()

    if args.build or args.force:
        build_index(force=args.force)
        return

    if args.query:
        rag = RagIndex()
        print(f"\nQuery: {args.query}\n")
        print("=" * 60)
        result = rag.retrieve(args.query, top_k=args.top_k)
        print(result)
        return

    parser.print_help()


if __name__ == "__main__":
    main()
