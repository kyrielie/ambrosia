#!/usr/bin/env python3
"""
AO3 Tag Synonym Scraper
=======================
Scrapes AO3 tag pages for synonyms, parent tags, and subtags.
Produces ao3_tag_seeds.db (SQLite) and AO3TagSeeds.swift (Swift embed).

Usage:
    python3 ao3_seed_scraper.py -i fandoms.txt tags.txt [--dry-run] [--limit N] [--resume]

Input text files contain one AO3 tag URL per line (blank lines and lines
starting with # are ignored):

    https://archiveofourown.org/tags/Marvel Cinematic Universe
    https://archiveofourown.org/tags/Hurt*s*Comfort
    # this line is a comment and will be skipped

The tag type hint ('fandom' or 'additional') is inferred from the URL path
if possible; otherwise it defaults to 'unknown'. You can also force a type
for all URLs in a file by naming the file fandoms.txt / fandom_*.txt
(treated as 'fandom') or tags.txt / additional_*.txt (treated as 'additional').
Any other filename → 'unknown' hint for every URL in that file.

Output files (written to ./output/ by default, override with --output-dir):
    ao3_tag_seeds.db        — SQLite database for direct use or inspection
    AO3TagSeeds.swift       — Hardcoded seed data for the Ambrosia Swift app

Rate limiting: 2-second minimum gap between requests (AO3 guidelines).
Automatically retries on 429 / 503 with exponential backoff.
State is checkpointed after every tag so --resume works after interruption.
"""

import sqlite3
import time
import json
import re
import sys
import os
import argparse
import logging
from datetime import datetime, timezone
from urllib.parse import unquote, urlencode, quote
from pathlib import Path

import requests
from bs4 import BeautifulSoup

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

OUTPUT_DIR = Path("./output")
DB_PATH    = OUTPUT_DIR / "ao3_tag_seeds.db"
SWIFT_PATH = OUTPUT_DIR / "AO3TagSeeds.swift"
STATE_PATH = OUTPUT_DIR / "scraper_state.json"

MIN_DELAY   = 2.0    # seconds between requests (AO3 rate-limit guideline)
BACKOFF_MAX = 120.0  # maximum backoff seconds on repeated errors
MAX_RETRIES = 5

HEADERS = {
    "User-Agent": "Ambrosia/1.0 AO3 EPUB reader (tag seed builder; contact: see app)",
    "Accept": "text/html,application/xhtml+xml",
    "Accept-Language": "en-US,en;q=0.9",
}

# ---------------------------------------------------------------------------
# Input file loader  (replaces hardcoded URL lists)
# ---------------------------------------------------------------------------

def _hint_from_filename(path):
    """Infer a tag-type hint from the input filename."""
    name = path.stem.lower()
    if "fandom" in name:
        return "fandom"
    if "additional" in name or name.startswith("tag"):
        return "additional"
    return "unknown"


def load_urls_from_files(paths):
    """
    Read one or more text files, each containing one AO3 tag URL per line.
    Blank lines and lines starting with '#' are ignored.

    Returns a deduplicated list of (url, tag_type_hint) in file order.
    The type hint is derived from the filename (see _hint_from_filename).
    """
    seen   = set()
    result = []
    for p in paths:
        hint = _hint_from_filename(p)
        try:
            file_lines = p.read_text(encoding="utf-8").splitlines()
        except OSError as exc:
            logging.error(f"Cannot read input file {p}: {exc}")
            sys.exit(1)
        for raw in file_lines:
            url = raw.strip()
            if not url or url.startswith("#"):
                continue
            if not url.startswith("https://archiveofourown.org/tags/"):
                logging.warning(f"Skipping unrecognised URL in {p.name}: {url!r}")
                continue
            if url not in seen:
                seen.add(url)
                result.append((url, hint))
    return result

# ---------------------------------------------------------------------------
# AO3 URL → display name decoding
# AO3 encodes special chars in tag names:
#   *s* → /   (ship separator)
#   *a* → &   (ampersand / "and")
#   *d* → .   (period)
#   *q* → ?   (question mark)
#   *h* → #   (hash)
# ---------------------------------------------------------------------------

AO3_DECODE = {
    "*s*": "/", "*a*": "&", "*d*": ".", "*q*": "?", "*h*": "#",
}
AO3_ENCODE = {v: k for k, v in AO3_DECODE.items()}

# AO3 fandom-category placeholder tags that are valid parents only for fandom
# tags.  For additional/character/relationship tags they are noise — skip them.
# Extend this set if other buckets cause the same pollution (e.g. "Original Work").
_FANDOM_BUCKETS = {"No Fandom"}

def ao3_decode(s: str) -> str:
    """Convert AO3 URL-safe tag name to display name.

    Order matters: percent-decode first so that %2A (encoded asterisk) becomes
    a literal * before we look for AO3 escape sequences like *s*.  The old
    order (substitute then unquote) silently left *s* intact whenever the
    surrounding asterisks had been percent-encoded by a browser or HTTP layer.
    """
    s = unquote(s)                       # %2A -> *  (must come first)
    for enc, dec in AO3_DECODE.items():  # *s* -> /  etc.
        s = s.replace(enc, dec)
    return s

def url_to_tag_name(url: str) -> str:
    """Extract the decoded tag name from a full AO3 tag URL."""
    path = url.split("/tags/", 1)[-1].split("?")[0].split("/")[0]
    return ao3_decode(path)

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

DDL = """
CREATE TABLE IF NOT EXISTS canonical_tags (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT    NOT NULL UNIQUE,
    tag_type     TEXT    NOT NULL DEFAULT 'unknown',
    -- 'fandom' | 'character' | 'relationship' | 'additional' | 'unknown'
    last_fetched TEXT    -- ISO-8601; NULL means seed/not-yet-fetched
);

CREATE TABLE IF NOT EXISTS tag_synonyms (
    synonym      TEXT    NOT NULL,
    canonical_id INTEGER NOT NULL REFERENCES canonical_tags(id) ON DELETE CASCADE,
    PRIMARY KEY (synonym)
);

CREATE TABLE IF NOT EXISTS tag_parent_links (
    -- Directed edge: child is more specific, parent is more general.
    -- Source: AO3 "Metatags" section (child→parent) and "Sub-tags" section
    -- (parent→child stored as child=subtag, parent=this).
    child_id     INTEGER NOT NULL REFERENCES canonical_tags(id) ON DELETE CASCADE,
    parent_id    INTEGER NOT NULL REFERENCES canonical_tags(id) ON DELETE CASCADE,
    PRIMARY KEY (child_id, parent_id)
);

CREATE TABLE IF NOT EXISTS tag_subtag_sections (
    -- Records the category label under which a child appeared in the Sub-tags
    -- block of a parent tag page, e.g. "Relationships", "Characters",
    -- "Additional Tags", or "Fandoms". Purely informational — the authoritative
    -- edge is in tag_parent_links.
    child_id     INTEGER NOT NULL REFERENCES canonical_tags(id) ON DELETE CASCADE,
    parent_id    INTEGER NOT NULL REFERENCES canonical_tags(id) ON DELETE CASCADE,
    section      TEXT    NOT NULL,   -- e.g. "Relationships", "Characters", ""
    PRIMARY KEY (child_id, parent_id)
);

-- Tracks which tags have been scraped so --resume works
CREATE TABLE IF NOT EXISTS scrape_log (
    tag_name     TEXT    NOT NULL PRIMARY KEY,
    scraped_at   TEXT    NOT NULL,
    status       TEXT    NOT NULL  -- 'ok' | 'not_canonical' | 'error'
);

CREATE INDEX IF NOT EXISTS idx_synonyms_canonical   ON tag_synonyms(canonical_id);
CREATE INDEX IF NOT EXISTS idx_parent_child         ON tag_parent_links(child_id);
CREATE INDEX IF NOT EXISTS idx_parent_parent        ON tag_parent_links(parent_id);
CREATE INDEX IF NOT EXISTS idx_subtag_section_child ON tag_subtag_sections(child_id);
CREATE INDEX IF NOT EXISTS idx_subtag_section_par   ON tag_subtag_sections(parent_id);
"""

def open_db(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path))
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript(DDL)
    conn.commit()
    return conn


def upsert_canonical(conn: sqlite3.Connection, name: str, tag_type: str) -> int:
    """Insert if not exists; return the canonical_tags.id.

    Never overwrites a known tag_type with 'unknown' — a scraped authoritative
    type must not be clobbered by a placeholder inserted as a side-effect of
    processing another tag's subtag/metatag list.

    Written as explicit SELECT + INSERT/UPDATE rather than relying on
    ON CONFLICT … DO UPDATE … WHERE or RETURNING, which have subtle
    behaviour differences across SQLite versions.
    """
    row = conn.execute(
        "SELECT id, tag_type FROM canonical_tags WHERE name=?", (name,)
    ).fetchone()
    if row is None:
        cur = conn.execute(
            "INSERT INTO canonical_tags(name, tag_type) VALUES(?,?)",
            (name, tag_type),
        )
        return cur.lastrowid
    existing_id, existing_type = row
    # Only overwrite if the incoming type is more specific than what's stored
    if tag_type != "unknown" and existing_type != tag_type:
        conn.execute(
            "UPDATE canonical_tags SET tag_type=? WHERE id=?",
            (tag_type, existing_id),
        )
    return existing_id


def insert_synonym(conn: sqlite3.Connection, synonym: str, canonical_id: int):
    conn.execute(
        "INSERT INTO tag_synonyms(synonym, canonical_id) VALUES(?,?) "
        "ON CONFLICT(synonym) DO UPDATE SET canonical_id=excluded.canonical_id",
        (synonym, canonical_id),
    )


def insert_parent(conn: sqlite3.Connection, child_id: int, parent_id: int):
    conn.execute(
        "INSERT INTO tag_parent_links(child_id, parent_id) VALUES(?,?) "
        "ON CONFLICT DO NOTHING",
        (child_id, parent_id),
    )


def log_scrape(conn: sqlite3.Connection, tag_name: str, status: str):
    now = datetime.now(timezone.utc).isoformat()
    conn.execute(
        "INSERT INTO scrape_log(tag_name, scraped_at, status) VALUES(?,?,?) "
        "ON CONFLICT(tag_name) DO UPDATE SET scraped_at=excluded.scraped_at, status=excluded.status",
        (tag_name, now, status),
    )
    conn.commit()


def already_scraped(conn: sqlite3.Connection, tag_name: str) -> bool:
    row = conn.execute(
        "SELECT status FROM scrape_log WHERE tag_name=?", (tag_name,)
    ).fetchone()
    return row is not None and row[0] == "ok"

# ---------------------------------------------------------------------------
# HTTP layer with rate limiting
# ---------------------------------------------------------------------------

_last_request_at: float = 0.0

def fetch_page(url: str, session: requests.Session) -> str | None:
    """Fetch a URL, honouring MIN_DELAY between requests. Returns HTML or None."""
    global _last_request_at

    # Enforce minimum gap
    elapsed = time.monotonic() - _last_request_at
    if elapsed < MIN_DELAY:
        time.sleep(MIN_DELAY - elapsed)

    backoff = 2.0
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            _last_request_at = time.monotonic()
            resp = session.get(url, headers=HEADERS, timeout=30, allow_redirects=True)

            if resp.status_code == 200:
                return resp.text
            elif resp.status_code in (429, 503):
                wait = min(backoff * (2 ** attempt), BACKOFF_MAX)
                logging.warning(f"Rate limited ({resp.status_code}), waiting {wait:.0f}s …")
                time.sleep(wait)
            elif resp.status_code == 404:
                logging.warning(f"404 for {url}")
                return None
            else:
                logging.warning(f"HTTP {resp.status_code} for {url}, attempt {attempt}")
                time.sleep(backoff * attempt)
        except requests.RequestException as exc:
            logging.warning(f"Request error: {exc}, attempt {attempt}")
            time.sleep(backoff * attempt)

    logging.error(f"Giving up on {url} after {MAX_RETRIES} attempts")
    return None

# ---------------------------------------------------------------------------
# Page parser
# ---------------------------------------------------------------------------

def _tag_name_from_href(href: str) -> str:
    """Extract and AO3-decode a tag name from an href like /tags/Hurt*s*Comfort."""
    path = href.split("/tags/", 1)[-1].split("/")[0].split("?")[0]
    return ao3_decode(path)


def _section_ul(header_el) -> "Tag | None":
    """
    Given a header element (h3, h4, dt, p), walk forward siblings until we
    find a <ul> or <dd> that contains tag links.  Returns the element or None.
    """
    sib = header_el.find_next_sibling()
    while sib:
        if sib.name in ("ul", "dd", "div"):
            if sib.find("a", href=lambda h: h and "/tags/" in h):
                return sib
        # Stop if we hit another heading — we've left this section
        if sib.name in ("h2", "h3", "h4", "dt"):
            break
        sib = sib.find_next_sibling()
    return None


def _walk_subtag_ul(ul_el, section_label: str, results: list):
    """
    Recursively walk a <ul class="tags tree index"> (or any <ul>) collecting
    subtag entries.  Handles nested <ul> inside <li> for grandchildren.

    Each entry appended to results is:
        {"name": str, "section": str, "children": [same structure, ...]}

    The top-level call should pass the <ul> directly under the section header.
    """
    for li in ul_el.find_all("li", recursive=False):
        a = li.find("a", class_="tag", href=True)
        if not a or "/tags/" not in a["href"]:
            # Try any <a href=/tags/…> inside this li (but not inside a nested ul)
            a = li.find("a", href=lambda h: h and "/tags/" in h)
        if not a:
            continue
        name = _tag_name_from_href(a["href"])
        entry = {"name": name, "section": section_label, "children": []}
        # Check for a nested <ul> — these are the subtags-of-subtags
        nested_ul = li.find("ul", recursive=False)
        if nested_ul:
            _walk_subtag_ul(nested_ul, section_label, entry["children"])
        results.append(entry)


def parse_tag_page(html: str, canonical_name: str) -> dict | None:
    """
    Parse an AO3 tag page using BeautifulSoup.  Returns a dict:

        {
          "is_canonical": bool,
          "merger_of":    str | None,  # if non-None: this tag is a synonym of merger_of;
                                       # scraper should follow that URL and record the synonym
          "tag_type":     str,   # 'fandom'|'character'|'relationship'|'additional'|'unknown'
          "synonyms":     [str], # tags that mean the same thing (flat list, canonical pages only)
          "metatags":     [str], # parent/broader tags (flat list)
          "subtags":      [      # structured subtag tree
              {
                "name":     str,
                "section":  str,   # "Relationships"|"Characters"|"Additional Tags"|
                                   # "Fandoms"|"" (unlabelled)
                "children": [...]  # same structure, recursive
              },
              ...
          ],
        }

    Returns None only if BeautifulSoup itself raises an unexpected exception.

    AO3 tag page variants
    ──────────────────────────────────────────────────────────────────────────
    1. Canonical tag — says "It's a canonical tag." (or similar).
       Has: "Tags with the same meaning:", "Metatags:", "Sub-tags:" sections.

    2. Merged/synonym tag — has a <div class="merger module"> saying
       "X has been made a synonym of <a>Y</a>."  No canonical blurb.
       is_canonical=False, merger_of=<canonical name>.
       Scraper must follow the canonical URL and register this tag as a synonym.

    3. Non-canonical, non-merged — exists but wranglers haven't touched it.
       is_canonical=False, merger_of=None.

    Real AO3 HTML structure (from live pages, not assumptions)
    ──────────────────────────────────────────────────────────
    Parent tags:  <div class="parent * listbox group">
                    <h3 class="heading">Parent tags (more general):</h3>
                    <ul class="tags commas index group"><li><a class="tag">…

    Merger:       <div class="merger module">
                    <h3 class="heading">Mergers</h3>
                    <p>X has been made a synonym of <a class="tag" href="/tags/…">Y</a></p>

    Synonyms:     <div class="synonym * listbox group"> (canonical page)
                    <h3 class="heading">Tags with the same meaning:</h3>
                    <ul>…

    Sub-tags:     <div class="child * listbox group"> or h3 "Sub-tags:"
    """
    try:
        soup = BeautifulSoup(html, "html.parser")
    except Exception as exc:
        logging.error(f"BeautifulSoup parse error: {exc}")
        return None

    # ── Scope to #main so we don't pick up nav/footer noise ──────────────────
    main = soup.find("div", id="main") or soup.find("main") or soup
    full_text = main.get_text(" ", strip=True).lower()

    # ── Merger detection ──────────────────────────────────────────────────────
    # A merged tag has <div class="merger module"> containing a <p> that says
    # "X has been made a synonym of <a class="tag" href="/tags/…">Y</a>."
    # These pages have NO canonical blurb — detect merger first.
    merger_of = None
    merger_div = main.find("div", class_="merger")
    if merger_div:
        # The canonical target is the <a class="tag"> inside the merger <p>
        a = merger_div.find("a", class_="tag", href=True)
        if a and "/tags/" in a["href"]:
            merger_of = _tag_name_from_href(a["href"])

    # ── Canonical status ──────────────────────────────────────────────────────
    # Canonical pages say "It's a canonical tag."
    # Merged pages (merger_of set) have no such text — is_canonical stays False.
    # Non-canonical, non-merged pages also have no such text.
    is_canonical = (
        "canonical tag" in full_text
        and "not a canonical tag" not in full_text
        and "is not canonical" not in full_text
        and "it's not canonical" not in full_text
    )

    # ── Tag type ──────────────────────────────────────────────────────────────
    # AO3 emits exactly one sentence like:
    #   "This tag belongs to the Additional Tags Category."
    #   "This tag belongs to the Fandom Category."
    # We extract only that sentence so that adjacent page text (e.g. "No Fandom"
    # next to "Tags with the same meaning:" collapsing into "fandom tags") can
    # never cause a false substring match.
    import re as _re
    tag_type = "unknown"
    _type_sentence = ""
    _m = _re.search(r"this tag belongs to the [^.]+\.", full_text)
    if _m:
        _type_sentence = _m.group(0)
    else:
        # Fallback: look for "<X> category" anywhere (older page layout)
        _m2 = _re.search(r"\b(fandom|relationship|character|additional tags?) category\b", full_text)
        if _m2:
            _type_sentence = _m2.group(0)

    if "fandom" in _type_sentence and "additional" not in _type_sentence:
        tag_type = "fandom"
    elif "relationship" in _type_sentence:
        tag_type = "relationship"
    elif "character" in _type_sentence:
        tag_type = "character"
    elif "additional" in _type_sentence:
        tag_type = "additional"

    # Early return for non-canonical pages — no wrangling sections to parse
    if not is_canonical:
        return {
            "is_canonical": False,
            "merger_of":    merger_of,
            "tag_type":     tag_type,
            "synonyms":     [],
            "metatags":     [],
            "subtags":      [],
        }

    # ── From here: canonical page only ───────────────────────────────────────

    # ── Parent tags ("Parent tags (more general):") ───────────────────────────
    # Real AO3 HTML uses <div class="parent * listbox group"> containing
    # <h3 class="heading">Parent tags (more general):</h3> and a <ul>.
    # Some wrangling UIs use "Metatags:" instead — check both.
    metatags = []

    parent_div = main.find("div", class_=re.compile(r"\bparent\b"))
    if parent_div:
        ul = parent_div.find("ul")
        if ul:
            for a in ul.find_all("a", class_="tag", href=True):
                name = _tag_name_from_href(a["href"])
                if name != canonical_name:
                    metatags.append(name)

    # Also check for a "Metatags:" dt/h3 (wrangling interface layout)
    for hdr in main.find_all(["h3", "h4", "dt"]):
        if "metatag" in hdr.get_text(" ", strip=True).lower():
            ul = _section_ul(hdr)
            if ul:
                for a in ul.find_all("a", class_="tag", href=True):
                    name = _tag_name_from_href(a["href"])
                    if name != canonical_name and name not in metatags:
                        metatags.append(name)
            break

    # ── Synonyms ("Tags with the same meaning:") ─────────────────────────────
    # Real AO3: <div class="synonym * listbox group"> with <ul> of <a class="tag">
    synonyms = []

    syn_div = main.find("div", class_=re.compile(r"\bsynonym\b"))
    if syn_div:
        ul = syn_div.find("ul")
        if ul:
            for a in ul.find_all("a", class_="tag", href=True):
                name = _tag_name_from_href(a["href"])
                if name != canonical_name:
                    synonyms.append(name)

    # Fallback: look for "same meaning" header (some page layouts)
    if not synonyms:
        for hdr in main.find_all(["h3", "h4", "dt", "p"]):
            if "same meaning" in hdr.get_text(" ", strip=True).lower():
                ul = _section_ul(hdr)
                if ul:
                    for a in ul.find_all("a", class_="tag", href=True):
                        name = _tag_name_from_href(a["href"])
                        if name != canonical_name:
                            synonyms.append(name)
                break

    # ── Sub-tags ──────────────────────────────────────────────────────────────
    # Real AO3: <div class="child * listbox group"> sections, one per category.
    # Each has an <h3 class="heading"> with the category name and a
    # <ul class="tags tree index"> that may have nested <ul> for grandchildren.
    subtags = []

    child_divs = main.find_all("div", class_=re.compile(r"\bchild\b"))
    if child_divs:
        for div in child_divs:
            # Section label from the h3 heading inside this div
            hdr = div.find(["h3", "h4"])
            section_label = hdr.get_text(" ", strip=True).rstrip(":") if hdr else ""
            ul = div.find("ul")
            if ul:
                _walk_subtag_ul(ul, section_label, subtags)
    else:
        # Fallback: text-based "Sub-tags:" header (older/wrangling layout)
        for hdr in main.find_all(["h3", "h4", "dt"]):
            txt = hdr.get_text(" ", strip=True).lower()
            if "sub-tag" in txt or "subtag" in txt:
                cursor = hdr.find_next_sibling()
                current_section = ""
                while cursor:
                    n = cursor.name if cursor.name else ""
                    if n in ("h2",):
                        break
                    if n in ("h3", "h4", "dt"):
                        clabel = cursor.get_text(" ", strip=True).lower()
                        if any(kw in clabel for kw in ("metatag", "same meaning",
                                                        "parent", "synonym")):
                            break
                        current_section = cursor.get_text(" ", strip=True).rstrip(":")
                        cursor = cursor.find_next_sibling()
                        continue
                    if n == "ul":
                        _walk_subtag_ul(cursor, current_section, subtags)
                    cursor = cursor.find_next_sibling()
                break

    return {
        "is_canonical": is_canonical,
        "merger_of":    merger_of,
        "tag_type":     tag_type,
        "synonyms":     synonyms,
        "metatags":     metatags,
        "subtags":      subtags,
    }

# ---------------------------------------------------------------------------
# Scraper
# ---------------------------------------------------------------------------

def _store_subtag_tree(conn: sqlite3.Connection, entries: list,
                       parent_id: int, depth: int = 0):
    """
    Recursively store a subtag tree returned by parse_tag_page.

    For each entry:
      - Upsert the tag as a canonical placeholder (type='unknown' if new).
      - Insert a tag_parent_links edge: child=entry, parent=parent_id.
      - Insert a tag_subtag_sections row recording the section label.
      - Recurse into entry["children"] with entry as the new parent.

    depth is used only for debug-level logging indentation.
    """
    # Map AO3 section heading → tag_type so subtag placeholders get a useful
    # type rather than 'unknown'.  Only applied when the tag has no known type
    # yet — upsert_canonical won't overwrite an existing non-'unknown' value.
    _SECTION_TYPE = {
        "fandoms":         "fandom",
        "fandom":          "fandom",
        "relationships":   "relationship",
        "relationship":    "relationship",
        "characters":      "character",
        "character":       "character",
        "additional tags": "additional",
        "additional tag":  "additional",
    }

    indent = "  " * (depth + 1)
    for entry in entries:
        name    = entry["name"]
        section = entry["section"]
        inferred_type = _SECTION_TYPE.get(section.lower(), "unknown")
        child_id = upsert_canonical(conn, name, inferred_type)
        insert_parent(conn, child_id, parent_id)
        # Record which section this child appeared under on the parent's page
        conn.execute(
            "INSERT INTO tag_subtag_sections(child_id, parent_id, section) "
            "VALUES(?,?,?) ON CONFLICT(child_id, parent_id) DO UPDATE "
            "SET section=excluded.section",
            (child_id, parent_id, section),
        )
        logging.debug(f"{indent}subtag [{section or '—'}]: {name!r}")
        if entry["children"]:
            _store_subtag_tree(conn, entry["children"], child_id, depth + 1)


def scrape_tag(url: str, conn: sqlite3.Connection, session: requests.Session,
               tag_type_hint: str = "unknown", dry_run: bool = False) -> str:
    """
    Fetch one tag page, parse it with BeautifulSoup, and persist all data.

    Writes:
      canonical_tags      — the tag itself (and any new parent/child placeholders)
      tag_synonyms        — tags with the same meaning
      tag_parent_links    — metatag edges (this→metatag) and subtag edges (child→this)
      tag_subtag_sections — section label for each subtag edge

    Returns:
      - A plain status string: 'ok' | 'not_canonical' | 'skip' | 'error'
      - Or a tuple ("merged", canonical_url) when this tag has been merged into
        another.  The caller should follow canonical_url and scrape it too.
    """
    canonical_name = url_to_tag_name(url)

    if dry_run:
        logging.info(f"[DRY-RUN] Would fetch: {canonical_name!r}")
        return "skip"

    logging.info(f"Fetching: {canonical_name!r}")
    html = fetch_page(url, session)
    if html is None:
        log_scrape(conn, canonical_name, "error")
        return "error"

    parsed = parse_tag_page(html, canonical_name)
    if parsed is None:
        log_scrape(conn, canonical_name, "error")
        return "error"

    if not parsed["is_canonical"]:
        merger_of = parsed.get("merger_of")
        if merger_of:
            # This tag has been merged into merger_of.
            # 1. Upsert the canonical target (may be a new placeholder).
            tag_type = parsed["tag_type"] if parsed["tag_type"] != "unknown" else tag_type_hint
            canonical_id = upsert_canonical(conn, merger_of, tag_type)
            # 2. Register this tag name as a synonym of the canonical target.
            insert_synonym(conn, canonical_name, canonical_id)
            conn.commit()
            log_scrape(conn, canonical_name, "merged")
            logging.info(f"  → merged into {merger_of!r} (recorded as synonym)")
            # 3. Return the canonical target URL so the caller can follow it.
            #    Encode back to AO3 URL format for fetch.
            encoded = quote(merger_of.replace("/", "*s*").replace("&", "*a*")
                                      .replace(".", "*d*").replace("?", "*q*")
                                      .replace("#", "*h*"))
            canonical_url = f"https://archiveofourown.org/tags/{encoded}"
            return ("merged", canonical_url)
        else:
            logging.info(f"  → not canonical (no merger info)")
            log_scrape(conn, canonical_name, "not_canonical")
            upsert_canonical(conn, canonical_name, tag_type_hint)
            conn.commit()
            return "not_canonical"

    # Prefer type from page over caller hint (page is authoritative)
    tag_type = parsed["tag_type"] if parsed["tag_type"] != "unknown" else tag_type_hint
    canonical_id = upsert_canonical(conn, canonical_name, tag_type)

    # ── Synonyms ──────────────────────────────────────────────────────────────
    for syn in parsed["synonyms"]:
        insert_synonym(conn, syn, canonical_id)
        logging.debug(f"  synonym: {syn!r}")

    # ── Metatags (broader parent tags assigned by AO3 wranglers) ─────────────
    for meta_name in parsed["metatags"]:
        # "No Fandom" (and similar buckets) are fandom-category placeholders.
        # AO3 wranglers assign them as parents to general additional/character/
        # relationship tags, but that pollutes the hierarchy for non-fandom tags.
        # Only allow them through when the child is itself a fandom tag.
        if meta_name in _FANDOM_BUCKETS and tag_type != "fandom":
            logging.debug(f"  skipping fandom-bucket metatag {meta_name!r} for {tag_type!r} tag")
            continue
        meta_id = upsert_canonical(conn, meta_name, "unknown")
        insert_parent(conn, canonical_id, meta_id)   # this tag is child of metatag
        logging.debug(f"  metatag: {meta_name!r}")

    # ── Sub-tags (structured tree, may be nested) ─────────────────────────────
    # _store_subtag_tree walks the tree and records:
    #   tag_parent_links:    child=subtag,  parent=canonical_id
    #   tag_subtag_sections: section label under which each child appeared
    _store_subtag_tree(conn, parsed["subtags"], canonical_id)

    # ── Bookkeeping ───────────────────────────────────────────────────────────
    now = datetime.now(timezone.utc).isoformat()
    conn.execute(
        "UPDATE canonical_tags SET last_fetched=? WHERE id=?", (now, canonical_id)
    )
    conn.commit()
    log_scrape(conn, canonical_name, "ok")

    def _count_subtag_tree(entries):
        return sum(1 + _count_subtag_tree(e["children"]) for e in entries)

    n_syn  = len(parsed["synonyms"])
    n_meta = len(parsed["metatags"])
    n_sub  = _count_subtag_tree(parsed["subtags"])
    logging.info(f"  → {n_syn} synonyms, {n_meta} metatags, {n_sub} subtags (tree)")
    return "ok"

# ---------------------------------------------------------------------------
# Swift code generator
# ---------------------------------------------------------------------------

SWIFT_HEADER = '''\
// AO3TagSeeds.swift
// Auto-generated by ao3_seed_scraper.py — DO NOT EDIT BY HAND.
// Generated: {timestamp}
//
// Usage (Phase 11 — Tag Synonyms):
//   On first launch, call AO3TagSeeds.loadIfNeeded(into: db)
//   where db is an AmbrosiaMetaDB write connection.
//   This inserts all seed rows in a single transaction with last_fetched = nil.

import Foundation

struct AO3TagSeeds {{

    // MARK: - Seed data

    /// (synonym, canonicalName, tagType)
    static let synonyms: [(synonym: String, canonical: String, tagType: String)] = [
{synonym_rows}
    ]

    /// (childName, parentName) — wrangling hierarchy
    static let parentLinks: [(child: String, parent: String)] = [
{parent_rows}
    ]

    // MARK: - Loader

    /// Call once on first launch (gate with UserDefaults "tagSeedLoaded").
    /// Inserts all seeds in a single SQLite transaction. Safe to call again —
    /// uses INSERT OR IGNORE so duplicates are silently skipped.
    static func loadIfNeeded(db: OpaquePointer) throws {{
        let alreadyLoaded = UserDefaults.standard.bool(forKey: "tagSeedLoaded")
        guard !alreadyLoaded else {{ return }}

        sqlite3_exec(db, "BEGIN", nil, nil, nil)

        let insertCanonical = """
            INSERT OR IGNORE INTO canonical_tags(name, tag_type)
            VALUES(?, ?)
            """
        let insertSynonym = """
            INSERT OR IGNORE INTO tag_synonyms(synonym, canonical_id)
            SELECT ?, id FROM canonical_tags WHERE name=?
            """
        let insertParent = """
            INSERT OR IGNORE INTO tag_parent_links(child_id, parent_id)
            SELECT c.id, p.id FROM canonical_tags c
            JOIN canonical_tags p ON p.name=?
            WHERE c.name=?
            """

        // Insert canonical names
        let canonicals = Set(synonyms.map(\\.canonical))
        for canonical in canonicals {{
            let type_ = synonyms.first(where: {{ $0.canonical == canonical }})?.tagType ?? "unknown"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, insertCanonical, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, canonical, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, type_, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }}

        // Insert synonyms
        for row in synonyms {{
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, insertSynonym, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, row.synonym, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, row.canonical, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }}

        // Insert parent links
        for row in parentLinks {{
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, insertParent, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, row.parent, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, row.child, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }}

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        UserDefaults.standard.set(true, forKey: "tagSeedLoaded")
    }}
}}
'''

def escape_swift_string(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')

def generate_swift(conn: sqlite3.Connection) -> str:
    rows = conn.execute("""
        SELECT s.synonym, c.name, c.tag_type
        FROM tag_synonyms s
        JOIN canonical_tags c ON c.id = s.canonical_id
        ORDER BY c.name, s.synonym
    """).fetchall()

    parent_rows_raw = conn.execute("""
        SELECT child.name, parent.name
        FROM tag_parent_links l
        JOIN canonical_tags child  ON child.id  = l.child_id
        JOIN canonical_tags parent ON parent.id = l.parent_id
        ORDER BY child.name, parent.name
    """).fetchall()

    synonym_lines = []
    for syn, canon, ttype in rows:
        s  = escape_swift_string(syn)
        c  = escape_swift_string(canon)
        t  = escape_swift_string(ttype)
        synonym_lines.append(f'        (synonym: "{s}", canonical: "{c}", tagType: "{t}")')

    parent_lines = []
    for child, parent in parent_rows_raw:
        ch = escape_swift_string(child)
        pa = escape_swift_string(parent)
        parent_lines.append(f'        (child: "{ch}", parent: "{pa}")')

    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    return SWIFT_HEADER.format(
        timestamp=timestamp,
        synonym_rows=",\n".join(synonym_lines) or "        // (empty — run scraper first)",
        parent_rows=",\n".join(parent_lines) or "        // (empty — run scraper first)",
    )

# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------

def print_stats(conn: sqlite3.Connection):
    n_canonical = conn.execute("SELECT COUNT(*) FROM canonical_tags").fetchone()[0]
    n_synonyms  = conn.execute("SELECT COUNT(*) FROM tag_synonyms").fetchone()[0]
    n_parents   = conn.execute("SELECT COUNT(*) FROM tag_parent_links").fetchone()[0]
    n_sections  = conn.execute("SELECT COUNT(*) FROM tag_subtag_sections").fetchone()[0]
    n_ok        = conn.execute("SELECT COUNT(*) FROM scrape_log WHERE status='ok'").fetchone()[0]
    n_err       = conn.execute("SELECT COUNT(*) FROM scrape_log WHERE status='error'").fetchone()[0]
    n_nc        = conn.execute("SELECT COUNT(*) FROM scrape_log WHERE status='not_canonical'").fetchone()[0]
    n_merged    = conn.execute("SELECT COUNT(*) FROM scrape_log WHERE status='merged'").fetchone()[0]
    # Count by type
    type_rows = conn.execute(
        "SELECT tag_type, COUNT(*) FROM canonical_tags GROUP BY tag_type ORDER BY COUNT(*) DESC"
    ).fetchall()
    print(f"\n{'='*55}")
    print(f"  Canonical tags   : {n_canonical:>6}")
    for ttype, cnt in type_rows:
        print(f"    {ttype:<18}: {cnt:>6}")
    print(f"  Synonyms         : {n_synonyms:>6}")
    print(f"  Parent/meta links: {n_parents:>6}")
    print(f"  Subtag sections  : {n_sections:>6}")
    print(f"  Scraped OK       : {n_ok:>6}")
    print(f"  Merged (followed): {n_merged:>6}")
    print(f"  Not canonical    : {n_nc:>6}")
    print(f"  Errors           : {n_err:>6}")
    print(f"{'='*55}\n")

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="AO3 tag synonym scraper",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "-i", "--input", nargs="+", required=False, default=[],
        metavar="FILE.txt",
        help=(
            "One or more text files, each with one AO3 tag URL per line. "
            "Blank lines and lines starting with # are ignored. "
            "Required unless --swift-only is passed."
        ),
    )
    parser.add_argument(
        "--output-dir", default="./output", metavar="DIR",
        help="Directory for ao3_tag_seeds.db and AO3TagSeeds.swift (default: ./output)",
    )
    parser.add_argument("--dry-run", action="store_true",
                        help="Print what would be fetched, don't hit the network")
    parser.add_argument("--limit", type=int, default=0,
                        help="Only process first N URLs total (0 = all)")
    parser.add_argument("--resume", action="store_true",
                        help="Skip URLs already successfully scraped")
    parser.add_argument("--swift-only", action="store_true",
                        help="Skip scraping; just regenerate AO3TagSeeds.swift from existing DB")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    if not args.swift_only and not args.input:
        parser.error("Provide at least one input file with -i / --input, or pass --swift-only.")

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )

    output_dir = Path(args.output_dir)
    db_path    = output_dir / "ao3_tag_seeds.db"
    swift_path = output_dir / "AO3TagSeeds.swift"

    conn = open_db(db_path)
    logging.info(f"DB: {db_path.resolve()}")

    if args.swift_only:
        swift = generate_swift(conn)
        swift_path.write_text(swift, encoding="utf-8")
        logging.info(f"Written: {swift_path.resolve()}")
        print_stats(conn)
        return

    session = requests.Session()

    input_paths = [Path(p) for p in args.input]
    all_tasks = load_urls_from_files(input_paths)
    if not all_tasks:
        logging.error("No URLs loaded. Pass at least one input file with -i / --input.")
        sys.exit(1)
    logging.info(f"Loaded {len(all_tasks)} URLs from {len(input_paths)} file(s).")

    if args.limit:
        all_tasks = all_tasks[:args.limit]

    total = len(all_tasks)
    counters = {"ok": 0, "skip": 0, "error": 0, "not_canonical": 0}

    for i, (url, tag_type_hint) in enumerate(all_tasks, 1):
        tag_name = url_to_tag_name(url)
        prefix = f"[{i:>3}/{total}]"

        if args.resume and not args.dry_run and already_scraped(conn, tag_name):
            logging.info(f"{prefix} SKIP (already scraped): {tag_name!r}")
            counters["skip"] += 1
            continue

        result = scrape_tag(url, conn, session,
                            tag_type_hint=tag_type_hint,
                            dry_run=args.dry_run)

        # scrape_tag returns either a plain status string or ("merged", canonical_url)
        if isinstance(result, tuple):
            status, follow_url = result
            counters[status] = counters.get(status, 0) + 1
            logging.info(f"{prefix} {status.upper()}: {tag_name!r}")
            # Follow the canonical URL unless already scraped
            follow_name = url_to_tag_name(follow_url)
            if not (args.resume and already_scraped(conn, follow_name)):
                logging.info(f"       Following merger → {follow_name!r}")
                follow_result = scrape_tag(follow_url, conn, session,
                                           tag_type_hint=tag_type_hint,
                                           dry_run=args.dry_run)
                follow_status = follow_result[0] if isinstance(follow_result, tuple) else follow_result
                counters[follow_status] = counters.get(follow_status, 0) + 1
                logging.info(f"       {follow_status.upper()}: {follow_name!r}")
        else:
            status = result
            counters[status] = counters.get(status, 0) + 1
            logging.info(f"{prefix} {status.upper()}: {tag_name!r}")

    # Generate Swift seed file
    if not args.dry_run:
        swift = generate_swift(conn)
        swift_path.write_text(swift, encoding="utf-8")
        logging.info(f"Written: {swift_path.resolve()}")

    print_stats(conn)
    print(f"Results: {counters}")
    conn.close()


if __name__ == "__main__":
    main()
