"""
test_ao3_scraper.py
===================
Regression + integrity tests for ao3_seed_scraper.py.

Run against your existing database:
    pytest test_ao3_scraper.py --db ./output/ao3_tag_seeds.db -v

Or point at any other path:
    pytest test_ao3_scraper.py --db /path/to/ao3_tag_seeds.db -v

Tests are split into three groups:
  - unit/         Pure logic tests; no DB or network required.
  - db/           Database integrity tests; need --db.
  - regression/   Specific known-bad cases; need --db.
"""

import sqlite3
import sys
import os
import pytest

# ---------------------------------------------------------------------------
# Allow pytest to find the scraper module regardless of working directory
# ---------------------------------------------------------------------------
sys.path.insert(0, os.path.dirname(__file__))
from ao3_seed_scraper import ao3_decode, url_to_tag_name, _tag_name_from_href, AO3_DECODE


# ---------------------------------------------------------------------------
# CLI option registered in conftest.py; fixture wired here
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def db_path(request):
    return request.config.getoption("--db")


@pytest.fixture(scope="session")
def conn(db_path):
    """Read-only connection to the seed database."""
    if not os.path.exists(db_path):
        pytest.skip(f"Database not found at {db_path!r} — pass --db <path>")
    # Plain connect (no URI) so paths with spaces or special characters work.
    # Tests are read-only by convention; no writes are issued.
    c = sqlite3.connect(str(db_path))
    c.execute("PRAGMA query_only=ON")
    yield c
    c.close()


# ===========================================================================
# unit/ — pure logic, no DB
# ===========================================================================

class TestAo3Decode:
    """ao3_decode() must convert every AO3 escape sequence to its display char."""

    @pytest.mark.parametrize("raw,expected", [
        ("Hurt*s*Comfort",          "Hurt/Comfort"),
        ("T*a*T",                   "T&T"),
        ("hello*d*world",           "hello.world"),
        ("What*q*",                 "What?"),
        ("hash*h*tag",              "hash#tag"),
        ("no_escapes",              "no_escapes"),
        ("multi*s**a**d*",          "multi/&."),
        # percent-encoding passthrough
        ("Spider-Man%3A%20Homecoming", "Spider-Man: Homecoming"),
    ])
    def test_known_escapes(self, raw, expected):
        assert ao3_decode(raw) == expected

    def test_hurt_slash_comfort_roundtrip(self):
        """
        Hurt*s*Comfort is the URL-safe form of Hurt/Comfort.
        ao3_decode must produce the display name, not store the raw form.
        This is the exact encoding behind the h/c → Hurt*s*Comfort bug.
        """
        assert ao3_decode("Hurt*s*Comfort") == "Hurt/Comfort"

    def test_idempotent_on_display_name(self):
        """Already-decoded names must pass through unchanged."""
        assert ao3_decode("Hurt/Comfort") == "Hurt/Comfort"

    def test_all_escape_keys_covered(self):
        """Every key in AO3_DECODE must be tested above (catches new additions)."""
        tested_escapes = {"*s*", "*a*", "*d*", "*q*", "*h*"}
        assert set(AO3_DECODE.keys()) == tested_escapes, (
            "AO3_DECODE has keys not covered by TestAo3Decode: "
            f"{set(AO3_DECODE.keys()) - tested_escapes}"
        )


class TestTagNameFromHref:
    """_tag_name_from_href() must decode AO3 hrefs to display names."""

    @pytest.mark.parametrize("href,expected", [
        ("/tags/Hurt*s*Comfort",                    "Hurt/Comfort"),
        ("/tags/Hurt*s*Comfort/works",              "Hurt/Comfort"),
        ("/tags/Hurt*s*Comfort?page=2",             "Hurt/Comfort"),
        ("/tags/T*a*T",                             "T&T"),
        ("/tags/No%20Fandom",                       "No Fandom"),
        ("https://archiveofourown.org/tags/Angst",  "Angst"),
    ])
    def test_href_decoding(self, href, expected):
        assert _tag_name_from_href(href) == expected

    def test_never_stores_star_s_star(self):
        """
        A tag href containing *s* must never produce a name with *s* in it.
        Storing the raw URL form is the root cause of the h/c bug.
        """
        result = _tag_name_from_href("/tags/Hurt*s*Comfort")
        assert "*s*" not in result, (
            f"_tag_name_from_href returned undecoded name {result!r}; "
            "expected 'Hurt/Comfort'"
        )


class TestUrlToTagName:
    """url_to_tag_name() is the entry point used by the scraper main loop."""

    @pytest.mark.parametrize("url,expected", [
        ("https://archiveofourown.org/tags/Hurt*s*Comfort",     "Hurt/Comfort"),
        ("https://archiveofourown.org/tags/h*s*c",              "h/c"),
        ("https://archiveofourown.org/tags/Angst",              "Angst"),
        ("https://archiveofourown.org/tags/No%20Fandom",        "No Fandom"),
        ("https://archiveofourown.org/tags/T*a*T%20More",       "T&T More"),
    ])
    def test_url_decoding(self, url, expected):
        assert url_to_tag_name(url) == expected


# ===========================================================================
# db/ — database integrity; skipped when --db file is absent
# ===========================================================================

class TestDbIntegrity:

    def test_no_undecoded_names_in_canonical_tags(self, conn):
        """
        No canonical tag name should contain a raw AO3 escape sequence.
        Presence of *s*, *a*, *d*, *q*, or *h* means ao3_decode was skipped
        somewhere in the pipeline — exactly the Hurt*s*Comfort bug pattern.
        """
        patterns = [f"%{esc}%" for esc in AO3_DECODE]
        placeholders = " OR ".join("name LIKE ?" for _ in patterns)
        rows = conn.execute(
            f"SELECT id, name, tag_type FROM canonical_tags WHERE {placeholders}",
            patterns,
        ).fetchall()
        if rows:
            details = "\n".join(f"  id={r[0]}  name={r[1]!r}  type={r[2]}" for r in rows)
            pytest.fail(
                f"{len(rows)} canonical tag(s) have undecoded AO3 escape sequences "
                f"in their name — they were stored without ao3_decode():\n{details}"
            )

    def test_no_undecoded_names_in_synonyms(self, conn):
        """Synonym names must also be fully decoded."""
        patterns = [f"%{esc}%" for esc in AO3_DECODE]
        placeholders = " OR ".join("synonym LIKE ?" for _ in patterns)
        rows = conn.execute(
            f"SELECT synonym, canonical_id FROM tag_synonyms WHERE {placeholders}",
            patterns,
        ).fetchall()
        if rows:
            details = "\n".join(f"  synonym={r[0]!r}  canonical_id={r[1]}" for r in rows)
            pytest.fail(
                f"{len(rows)} synonym(s) have undecoded AO3 escape sequences:\n{details}"
            )

    def test_no_duplicate_canonicals_differing_only_by_encoding(self, conn):
        """
        If two rows in canonical_tags decode to the same display name they are
        the same AO3 tag stored twice — once raw, once decoded.
        This is the structural cause of the split Hurt/Comfort / Hurt*s*Comfort rows.
        """
        rows = conn.execute("SELECT name FROM canonical_tags").fetchall()
        decoded_to_raws: dict[str, list[str]] = {}
        for (name,) in rows:
            key = ao3_decode(name)
            decoded_to_raws.setdefault(key, []).append(name)

        dupes = {k: v for k, v in decoded_to_raws.items() if len(v) > 1}
        if dupes:
            details = "\n".join(
                f"  decoded={k!r}  stored_as={v}" for k, v in sorted(dupes.items())
            )
            pytest.fail(
                f"{len(dupes)} tag(s) are stored under multiple encodings "
                f"(one decoded, one raw):\n{details}"
            )

    def test_synonyms_all_have_valid_canonical(self, conn):
        """Every synonym must point to an existing canonical_tags row."""
        orphans = conn.execute("""
            SELECT s.synonym, s.canonical_id
            FROM tag_synonyms s
            LEFT JOIN canonical_tags c ON c.id = s.canonical_id
            WHERE c.id IS NULL
        """).fetchall()
        if orphans:
            details = "\n".join(f"  {r[0]!r} → id {r[1]}" for r in orphans)
            pytest.fail(f"{len(orphans)} synonym(s) point to missing canonical ids:\n{details}")

    def test_parent_links_have_valid_endpoints(self, conn):
        """Both ends of every tag_parent_links edge must exist in canonical_tags."""
        bad = conn.execute("""
            SELECT l.child_id, l.parent_id
            FROM tag_parent_links l
            LEFT JOIN canonical_tags child  ON child.id  = l.child_id
            LEFT JOIN canonical_tags parent ON parent.id = l.parent_id
            WHERE child.id IS NULL OR parent.id IS NULL
        """).fetchall()
        assert bad == [], f"{len(bad)} parent link(s) reference missing canonical ids: {bad[:5]}"

    def test_no_self_parent_links(self, conn):
        """A tag cannot be its own parent."""
        self_loops = conn.execute(
            "SELECT child_id FROM tag_parent_links WHERE child_id = parent_id"
        ).fetchall()
        assert self_loops == [], f"Self-referencing parent links found: {self_loops}"


# ===========================================================================
# regression/ — specific known-bad cases
# ===========================================================================

class TestHurtComfortRegression:
    """
    Regression suite for the h/c → Hurt*s*Comfort mis-mapping.

    h/c is a common synonym for the Hurt/Comfort *additional* tag.
    It must NOT resolve to a raw-encoded or fandom-typed canonical.
    """

    def test_hc_synonym_exists(self, conn):
        """h/c must be present as a synonym in the DB."""
        row = conn.execute(
            "SELECT canonical_id FROM tag_synonyms WHERE synonym = 'h/c'"
        ).fetchone()
        assert row is not None, "'h/c' is missing from tag_synonyms entirely"

    def test_hc_resolves_to_hurt_comfort_not_raw(self, conn):
        """
        h/c's canonical must be 'Hurt/Comfort', not 'Hurt*s*Comfort'.
        Failing here means the merger href was stored without ao3_decode().
        """
        row = conn.execute("""
            SELECT c.name, c.tag_type
            FROM tag_synonyms s
            JOIN canonical_tags c ON c.id = s.canonical_id
            WHERE s.synonym = 'h/c'
        """).fetchone()
        if row is None:
            pytest.skip("h/c not in synonyms — run test_hc_synonym_exists first")

        canonical_name, tag_type = row
        assert canonical_name == "Hurt/Comfort", (
            f"h/c resolves to {canonical_name!r} (type={tag_type!r}) "
            f"instead of 'Hurt/Comfort'. "
            f"{'Raw AO3 encoding was stored — ao3_decode() was not applied.' if '*s*' in canonical_name else ''}"
        )

    def test_hc_canonical_is_not_fandom_type(self, conn):
        """
        The canonical that h/c points to must not be tag_type='fandom'.
        h/c is an additional-tag synonym; a fandom-typed canonical means
        the scraper landed on the wrong Hurt/Comfort tag.
        """
        row = conn.execute("""
            SELECT c.name, c.tag_type
            FROM tag_synonyms s
            JOIN canonical_tags c ON c.id = s.canonical_id
            WHERE s.synonym = 'h/c'
        """).fetchone()
        if row is None:
            pytest.skip("h/c not in synonyms")

        canonical_name, tag_type = row
        assert tag_type != "fandom", (
            f"h/c → {canonical_name!r} has tag_type='fandom'; "
            "expected 'additional' or 'unknown'. "
            "The scraper followed a merger into a fandom tag with the same display name."
        )

    def test_hurt_comfort_additional_exists(self, conn):
        """
        canonical_tags must contain exactly one 'Hurt/Comfort' row and it must
        not be tag_type='fandom'.  A fandom-typed row with this name (or the raw
        'Hurt*s*Comfort' form) indicates the decode bug is present.
        """
        rows = conn.execute(
            "SELECT id, name, tag_type FROM canonical_tags "
            "WHERE name IN ('Hurt/Comfort', 'Hurt*s*Comfort')"
        ).fetchall()

        names = {r[1] for r in rows}

        assert "Hurt*s*Comfort" not in names, (
            "canonical_tags contains 'Hurt*s*Comfort' (undecoded). "
            "This row should be 'Hurt/Comfort' — ao3_decode() was not applied when inserting it."
        )

        assert "Hurt/Comfort" in names, (
            "canonical_tags has no 'Hurt/Comfort' row at all. "
            "The tag was either never scraped or stored only in raw form."
        )

        hc_row = next(r for r in rows if r[1] == "Hurt/Comfort")
        assert hc_row[2] != "fandom", (
            f"'Hurt/Comfort' is stored with tag_type='fandom' (id={hc_row[0]}). "
            "It should be 'additional' (or 'unknown' if not yet scraped directly). "
            "This causes h/c to be associated with the wrong canonical."
        )


class TestAo3DecodePercentEncoded:
    """
    ao3_decode must handle percent-encoded asterisks (%2A).
    This covers the root cause of the 19-tag pollution: browsers and some
    HTTP layers encode * as %2A, so *s* arrives as %2As%2A.  The fix is to
    unquote() before substituting AO3 sequences, not after.
    """

    @pytest.mark.parametrize("raw,expected", [
        ("Hurt%2As%2AComfort",      "Hurt/Comfort"),
        ("T%2Aa%2AT",               "T&T"),
        ("hello%2Ad%2Aworld",       "hello.world"),
        ("What%2Aq%2A",             "What?"),
        ("hash%2Ah%2Atag",          "hash#tag"),
        # Mixed: some encoded, some literal
        ("Hurt%2As%2AComfort*a*T",  "Hurt/Comfort&T"),
    ])
    def test_percent_encoded_escapes(self, raw, expected):
        assert ao3_decode(raw) == expected, (
            f"ao3_decode({raw!r}) = {ao3_decode(raw)!r}, expected {expected!r}. "
            "Did you fix the unquote() ordering? It must run before the *s* substitution."
        )
