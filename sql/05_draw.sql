-- Draw the sample, and attach the weight that makes it usable.
--
-- Inside a stratum the rows are not taken off the top. They are ordered by
-- topic (with `hash` breaking ties, which is the shuffle) and then taken at a
-- fixed stride, so a stratum of 400 rows asked for 25 returns 25 rows spread
-- across its whole topic range instead of 25 rows about one topic. That is a
-- systematic sample, and in SQL it is one window function:
--
--   bucket = floor((row_number - 1) * n_draw / n_rows)
--
-- gives exactly `n_draw` equal blocks over the ordered stratum; taking the
-- first row of each block takes one row per block.
--
-- The weight is the inverse sampling fraction, n_rows / n_draw: how many corpus
-- rows each sampled row is standing in for. It is the only thing that makes the
-- sample say anything about the corpus rather than about itself.

DROP TABLE IF EXISTS sample;
CREATE TABLE sample (
    id       TEXT    NOT NULL PRIMARY KEY,
    platform TEXT    NOT NULL,
    stratum  TEXT    NOT NULL,
    topic    INTEGER NOT NULL,
    outcome  INTEGER NOT NULL,
    weight   REAL    NOT NULL
);

INSERT INTO sample (id, platform, stratum, topic, outcome, weight)
WITH eligible AS (
    SELECT c.id,
           c.platform,
           c.platform || ' | ' || c.type || ' | ' || c.length_bin AS stratum,
           c.topic,
           c.outcome,
           c.hash
    FROM corpus_stratified c
),
positioned AS (
    SELECT e.id, e.platform, e.stratum, e.topic, e.outcome,
           q.n_rows, q.n_draw,
           ROW_NUMBER() OVER (PARTITION BY e.stratum
                              ORDER BY e.topic, e.hash, e.id) AS rn
    FROM eligible e
    JOIN quota q ON q.stratum = e.stratum
    WHERE q.n_draw > 0
),
bucketed AS (
    SELECT id, platform, stratum, topic, outcome, n_rows, n_draw, rn,
           CAST((rn - 1) * n_draw AS INTEGER) / n_rows AS bucket
    FROM positioned
),
picked AS (
    SELECT id, platform, stratum, topic, outcome, n_rows, n_draw,
           ROW_NUMBER() OVER (PARTITION BY stratum, bucket ORDER BY rn) AS within
    FROM bucketed
)
SELECT id, platform, stratum, topic, outcome,
       n_rows * 1.0 / n_draw
FROM picked
WHERE within = 1;

CREATE INDEX idx_sample_stratum ON sample (stratum);
