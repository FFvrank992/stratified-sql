-- Strata: platform x type x length bin.
--
-- The length bin is derived, not stored, so the cut points live only in
-- `design`. A stratum is the unit the sample is allocated over and the unit a
-- weight is attached to, so it has to be defined exactly once.

DROP VIEW IF EXISTS corpus_stratified;
CREATE VIEW corpus_stratified AS
SELECT
    c.id,
    c.platform,
    c.type,
    c.n_words,
    c.topic,
    c.outcome,
    c.hash,
    CASE
        WHEN c.n_words <= (SELECT value FROM design WHERE key = 'short_max_words')
            THEN 'short'
        WHEN c.n_words <= (SELECT value FROM design WHERE key = 'medium_max_words')
            THEN 'medium'
        ELSE 'long'
    END AS length_bin
FROM corpus c;

DROP VIEW IF EXISTS stratum_sizes;
CREATE VIEW stratum_sizes AS
SELECT
    platform,
    platform || ' | ' || type || ' | ' || length_bin AS stratum,
    COUNT(*)                                          AS n_rows
FROM corpus_stratified
GROUP BY platform, stratum;
