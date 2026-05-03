#!/usr/bin/env python3
"""
Balatro wiki scraper — builds wiki/ filesystem from balatrowiki.org.

Usage:
    python3 scrape_wiki.py            # scrape everything
    python3 scrape_wiki.py --force    # re-download even if files exist

Output tree:
    wiki/jokers/      one .md per joker (152 total)
    wiki/tarot/       one .md per tarot card (22)
    wiki/planet/      one .md per planet card (15)
    wiki/spectral/    one .md per spectral card
    wiki/voucher/     one .md per voucher
    wiki/blind/       one .md per boss blind
    wiki/mechanic/    hands.md, scoring.md
"""

import argparse
import html.parser
import json
import os
import re
import time
import urllib.request
from pathlib import Path

BASE_URL   = "https://balatrowiki.org"
WIKI_DIR   = Path(__file__).parent / "wiki"
RATE_LIMIT = 0.8   # seconds between requests

CATEGORIES = {
    "jokers":   ("Category:Jokers",        "wiki/jokers"),
    "tarot":    ("Category:Tarot Cards",   "wiki/tarot"),
    "planet":   ("Category:Planet Cards",  "wiki/planet"),
    "spectral": ("Category:Spectral Cards","wiki/spectral"),
    "voucher":  ("Category:Vouchers",      "wiki/voucher"),
    "blind":    ("Category:Boss Blinds",   "wiki/blind"),
}

STATIC_PAGES = [
    ("Poker_Hands",     "wiki/mechanic/hands.md"),
    ("Scoring",         "wiki/mechanic/scoring.md"),
    ("Blinds_and_Antes","wiki/mechanic/blinds_overview.md"),
    ("Decks",           "wiki/mechanic/decks.md"),
]


# ── HTTP ─────────────────────────────────────────────────────────────────────

def fetch(url, retries=3):
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "BalatroWikiBot/1.0 (educational)"})
            with urllib.request.urlopen(req, timeout=15) as r:
                return r.read().decode("utf-8", "replace")
        except Exception as e:
            if attempt == retries - 1:
                raise
            print(f"    retry {attempt+1}: {e}")
            time.sleep(2)


# ── MediaWiki API ─────────────────────────────────────────────────────────────

def get_category_members(category_title):
    """Return list of page titles in a MediaWiki category."""
    members = []
    cmcontinue = None
    while True:
        params = f"action=query&list=categorymembers&cmtitle={urllib.request.quote(category_title)}&cmlimit=500&format=json&cmtype=page"
        if cmcontinue:
            params += f"&cmcontinue={urllib.request.quote(cmcontinue)}"
        data = json.loads(fetch(f"{BASE_URL}/api.php?{params}"))
        members.extend(m["title"] for m in data.get("query", {}).get("categorymembers", []))
        cont = data.get("continue", {})
        cmcontinue = cont.get("cmcontinue")
        if not cmcontinue:
            break
        time.sleep(RATE_LIMIT)
    return members


# ── HTML → Markdown ───────────────────────────────────────────────────────────

class WikiPageParser(html.parser.HTMLParser):
    """
    Extracts the main content from a balatrowiki.org article page.
    Converts headings, paragraphs, lists, and table cells to simple markdown.
    """
    def __init__(self):
        super().__init__()
        self.output   = []
        self.in_content = False
        self.skip_depth = 0
        self.tag_stack  = []
        self.list_depth = 0
        self._cur_text  = []
        self._in_cell   = False
        self._row_cells = []
        self._in_table  = False
        self._table_rows = []

    # tags that should be skipped entirely (with their children)
    SKIP_TAGS = {"script", "style", "nav", "footer", "sup", "figure",
                 "noscript", ".mw-editsection"}

    def handle_starttag(self, tag, attrs):
        attrs_dict = dict(attrs)
        cls = attrs_dict.get("class", "")
        idd = attrs_dict.get("id", "")

        # detect main content start
        if tag == "div" and ("mw-parser-output" in cls or "mw-content-text" in cls):
            self.in_content = True

        # skip sidebars, edit links, categories, etc.
        if tag in self.SKIP_TAGS or any(x in cls for x in
                ["mw-editsection", "navbox", "catlinks", "mw-jump-link",
                 "noprint", "infobox", "toc", "custom-tooltip"]):
            self.skip_depth += 1

        if self.skip_depth:
            self.tag_stack.append(tag)
            return

        if not self.in_content:
            return

        self.tag_stack.append(tag)

        if tag in ("h1","h2","h3","h4"):
            level = int(tag[1])
            self._flush()
            self.output.append("\n" + "#" * level + " ")
        elif tag == "p":
            self._flush()
            self.output.append("\n")
        elif tag in ("ul","ol"):
            self.list_depth += 1
        elif tag == "li":
            self._flush()
            self.output.append("\n" + "  " * (self.list_depth - 1) + "- ")
        elif tag == "table":
            self._in_table = True
            self._table_rows = []
        elif tag == "tr":
            self._row_cells = []
        elif tag in ("td","th"):
            self._flush()
            self._in_cell = True
        elif tag == "br":
            self.output.append("  \n")

    def handle_endtag(self, tag):
        if self.skip_depth:
            if self.tag_stack and self.tag_stack[-1] == tag:
                self.tag_stack.pop()
            self.skip_depth = max(0, self.skip_depth - 1)
            return

        if self.tag_stack and self.tag_stack[-1] == tag:
            self.tag_stack.pop()

        if not self.in_content:
            return

        if tag in ("h1","h2","h3","h4","p","li"):
            self._flush()
            self.output.append("\n")
        elif tag in ("ul","ol"):
            self.list_depth = max(0, self.list_depth - 1)
        elif tag in ("td","th"):
            cell = "".join(self._cur_text).strip()
            self._cur_text = []
            self._row_cells.append(cell)
            self._in_cell = False
        elif tag == "tr":
            if self._row_cells:
                self._table_rows.append(self._row_cells)
                self._row_cells = []
        elif tag == "table":
            self._render_table()
            self._in_table = False
            self._table_rows = []

    def handle_data(self, data):
        if self.skip_depth or not self.in_content:
            return
        text = data  # preserve whitespace within inline context
        if self._in_cell:
            self._cur_text.append(text)
        else:
            self.output.append(text)

    def _flush(self):
        # nothing to flush for non-cell context; cur_text is cell-only
        pass

    def _render_table(self):
        """Render table rows as a simple markdown pipe table."""
        if not self._table_rows:
            return
        self.output.append("\n")
        for i, row in enumerate(self._table_rows):
            self.output.append("| " + " | ".join(c.replace("\n"," ").strip() for c in row) + " |\n")
            if i == 0:
                self.output.append("|" + "|".join("---" for _ in row) + "|\n")
        self.output.append("\n")

    def get_text(self):
        return "".join(self.output)


def page_to_markdown(title, html_content):
    """Parse a wiki HTML page and return clean markdown."""
    p = WikiPageParser()
    p.feed(html_content)
    raw = p.get_text()

    # Remove excessive blank lines
    raw = re.sub(r"\n{3,}", "\n\n", raw)

    # Remove navigation artifacts
    raw = re.sub(r"Jump to navigation\s*\n", "", raw)
    raw = re.sub(r"Jump to search\s*\n", "", raw)
    raw = re.sub(r"From Balatro Wiki\s*\n", "", raw)
    raw = re.sub(r"Contents\s*\n", "", raw)

    # Clean up leading/trailing whitespace per line
    lines = [line.rstrip() for line in raw.splitlines()]
    return "\n".join(lines).strip()


# ── filename normalisation ────────────────────────────────────────────────────

def title_to_filename(title):
    """'Eight Ball' → 'eight_ball', 'Riff-Raff' → 'riff-raff'"""
    name = title.lower()
    name = re.sub(r"[^\w\-]", "_", name)   # non-word chars → _
    name = re.sub(r"_+", "_", name)         # collapse underscores
    name = name.strip("_")
    return name


def title_to_wiki_slug(title):
    """'Eight Ball' → 'Eight_Ball'"""
    return title.replace(" ", "_")


# ── scraping ──────────────────────────────────────────────────────────────────

def scrape_entity(title, out_path, force=False):
    """Fetch one wiki page, convert to markdown, write to out_path."""
    out_path = Path(out_path)
    if out_path.exists() and not force:
        return False   # already done

    slug = title_to_wiki_slug(title)
    url  = f"{BASE_URL}/w/{slug}"
    try:
        html_content = fetch(url)
    except Exception as e:
        print(f"    ERROR fetching {url}: {e}")
        return False

    md = page_to_markdown(title, html_content)
    if len(md) < 50:
        print(f"    WARN: very short content for {title} ({len(md)} chars)")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(f"# {title}\n\n{md}\n", encoding="utf-8")
    return True


def scrape_category(category_title, out_dir, force=False):
    """Fetch all pages in a category and write to out_dir."""
    out_dir = Path(out_dir)
    print(f"\n[{category_title}]")
    members = get_category_members(category_title)
    # filter out the category index page itself
    members = [m for m in members if m != category_title.replace("Category:", "")]
    print(f"  {len(members)} pages")

    written = 0
    for title in members:
        fname = title_to_filename(title) + ".md"
        out_path = out_dir / fname
        existed = out_path.exists()
        time.sleep(RATE_LIMIT)
        did_write = scrape_entity(title, out_path, force=force)
        status = "wrote" if did_write else ("skip" if existed else "FAILED")
        print(f"  [{status:5s}] {title}")
        if did_write:
            written += 1

    print(f"  → {written} new files in {out_dir}")
    return written


def scrape_static_pages(force=False):
    """Scrape fixed pages like Poker_Hands, Scoring, etc."""
    print("\n[Static mechanic pages]")
    for slug, out_rel in STATIC_PAGES:
        out_path = WIKI_DIR.parent / out_rel
        title = slug.replace("_", " ")
        existed = out_path.exists()
        time.sleep(RATE_LIMIT)
        did_write = scrape_entity(title, out_path, force=force)
        status = "wrote" if did_write else ("skip" if existed else "FAILED")
        print(f"  [{status:5s}] {title}")


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Scrape balatrowiki.org into wiki/")
    parser.add_argument("--force", action="store_true", help="Re-download even if files exist")
    parser.add_argument("--only",  help="Only scrape one category (e.g. jokers, tarot, blind)")
    args = parser.parse_args()

    print(f"Wiki dir: {WIKI_DIR}")
    WIKI_DIR.mkdir(exist_ok=True)

    total = 0
    for key, (category_title, out_subdir) in CATEGORIES.items():
        if args.only and key != args.only:
            continue
        out_dir = WIKI_DIR.parent / out_subdir
        total += scrape_category(category_title, out_dir, force=args.force)
        time.sleep(RATE_LIMIT)

    if not args.only:
        scrape_static_pages(force=args.force)

    print(f"\nDone. {total} new files written.")
    print(f"Wiki tree: {WIKI_DIR}")


if __name__ == "__main__":
    main()
