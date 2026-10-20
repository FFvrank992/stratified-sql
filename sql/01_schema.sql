-- The corpus as loaded, plus the design constants in one place.
--
-- `hash` is a deterministic 32-bit value derived from `id`. Everywhere the
-- design needs a shuffle, it orders by `hash`, so the whole pipeline is
-- reproducible without a seeded RNG inside the database.

DROP TABLE IF EXISTS corpus;
CREATE TABLE corpus (
    id       TEXT    NOT NULL PRIMARY KEY,
    platform TEXT    NOT NULL,
    type     TEXT    NOT NULL,
    n_words  INTEGER NOT NULL,
    topic    INTEGER NOT NULL,   -- -1 means the topic model left it unassigned
    outcome  INTEGER NOT NULL,   -- 0/1; in the real design this is a human label
    hash     INTEGER NOT NULL
);

DROP TABLE IF EXISTS design;
CREATE TABLE design (
    key   TEXT    NOT NULL PRIMARY KEY,
    value NUMERIC NOT NULL
);

-- These are the numbers the sample is built from. Changing one here changes
-- the whole pipeline; nothing downstream hard-codes them.
INSERT INTO design (key, value) VALUES
    ('n_draw',             7000),   -- total rows to draw
    ('max_platform_share', 0.40),   -- no platform may exceed this of the sample
    ('min_per_stratum',    25),     -- floor, so small strata stay usable
    ('short_max_words',    25),     -- length bin cut points
    ('medium_max_words',   100);

CREATE INDEX idx_corpus_platform ON corpus (platform);
CREATE INDEX idx_corpus_hash     ON corpus (hash);
