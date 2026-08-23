CREATE TABLE canonical_tags (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT    NOT NULL UNIQUE,
    tag_type     TEXT    NOT NULL DEFAULT 'unknown',
    -- 'fandom' | 'character' | 'relationship' | 'additional' | 'unknown'
    last_fetched TEXT    -- ISO-8601; NULL means seed/not-yet-fetched
);
CREATE TABLE tag_synonyms (
    synonym      TEXT    NOT NULL,
    canonical_id INTEGER NOT NULL REFERENCES canonical_tags(id) ON DELETE CASCADE,
    PRIMARY KEY (synonym)
);
CREATE INDEX idx_synonyms_canonical   ON tag_synonyms(canonical_id);
CREATE TABLE tag_parent_links (
    -- Directed edge: child is more specific, parent is more general.
    -- Source: AO3 "Metatags" section (child→parent) and "Sub-tags" section
    -- (parent→child stored as child=subtag, parent=this).
    child_id     INTEGER NOT NULL REFERENCES canonical_tags(id) ON DELETE CASCADE,
    parent_id    INTEGER NOT NULL REFERENCES canonical_tags(id) ON DELETE CASCADE,
    PRIMARY KEY (child_id, parent_id)
);
CREATE INDEX idx_parent_child         ON tag_parent_links(child_id);
CREATE INDEX idx_parent_parent        ON tag_parent_links(parent_id);
CREATE TABLE tag_subtag_sections (
    -- Records the category label under which a child appeared in the Sub-tags
    -- block of a parent tag page, e.g. "Relationships", "Characters",
    -- "Additional Tags", or "Fandoms". Purely informational — the authoritative
    -- edge is in tag_parent_links.
    child_id     INTEGER NOT NULL REFERENCES canonical_tags(id) ON DELETE CASCADE,
    parent_id    INTEGER NOT NULL REFERENCES canonical_tags(id) ON DELETE CASCADE,
    section      TEXT    NOT NULL,   -- e.g. "Relationships", "Characters", ""
    PRIMARY KEY (child_id, parent_id)
);
CREATE INDEX idx_subtag_section_child ON tag_subtag_sections(child_id);
CREATE INDEX idx_subtag_section_par   ON tag_subtag_sections(parent_id);
