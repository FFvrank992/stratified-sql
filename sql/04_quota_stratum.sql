-- Level 2: split each platform's quota across its strata, with a floor.
--
-- Same water-filling as level 1, with two differences: it runs per platform
-- (every window is PARTITION BY platform), and each stratum first gets a floor
-- so that a stratum holding 300 rows is not handed 2 and rendered useless.
--
-- Floors are taken off the top, then the remainder is water-filled in
-- proportion to stratum size, limited by what is left in each stratum.
--
-- Guard: if the floors alone would exceed a platform's quota, that platform
-- drops its floors and falls back to plain proportional allocation. Honouring
-- a floor you cannot afford would silently overrun the total.

DROP TABLE IF EXISTS quota;
CREATE TABLE quota (
    platform   TEXT    NOT NULL,
    stratum    TEXT    NOT NULL PRIMARY KEY,
    n_rows     INTEGER NOT NULL,   -- rows this stratum has in the corpus
    n_draw     INTEGER NOT NULL,   -- rows to draw from it
    floor_kept INTEGER NOT NULL    -- 1 if the floor was affordable, 0 if dropped
);

INSERT INTO quota (platform, stratum, n_rows, n_draw, floor_kept)
WITH consts AS (
    SELECT (SELECT value FROM design WHERE key = 'min_per_stratum') AS floor_n
),
-- Each stratum, its platform's quota, and whether that platform can afford
-- a floor on every one of its strata.
base AS (
    SELECT s.platform,
           s.stratum,
           s.n_rows,
           pq.n_draw AS quota,
           CASE WHEN SUM(MIN(c.floor_n, s.n_rows)) OVER (PARTITION BY s.platform)
                     <= pq.n_draw
                THEN 1 ELSE 0 END AS floor_kept
    FROM stratum_sizes s
    JOIN platform_quota pq ON pq.platform = s.platform
    CROSS JOIN consts c
),
-- Floors off the top (or zero, if this platform could not afford them).
seeded AS (
    SELECT b.platform, b.stratum, b.n_rows, b.quota, b.floor_kept,
           CASE WHEN b.floor_kept = 1
                THEN MIN((SELECT floor_n FROM consts), b.n_rows)
                ELSE 0 END AS seed
    FROM base b
),
headroom AS (
    SELECT platform, stratum, n_rows, quota, floor_kept, seed,
           n_rows - seed                                          AS room,
           quota - SUM(seed) OVER (PARTITION BY platform)          AS remaining,
           (n_rows - seed) * 1.0 / n_rows                          AS ratio,
           ROW_NUMBER() OVER (PARTITION BY platform
                              ORDER BY (n_rows - seed) * 1.0 / n_rows, stratum) AS rn
    FROM seeded
),
running AS (
    SELECT platform, stratum, n_rows, seed, room, remaining, ratio, rn,
           SUM(room)   OVER (PARTITION BY platform ORDER BY rn
                             ROWS UNBOUNDED PRECEDING)             AS cum_room,
           SUM(n_rows) OVER (PARTITION BY platform ORDER BY rn
                             ROWS UNBOUNDED PRECEDING)             AS cum_size,
           SUM(n_rows) OVER (PARTITION BY platform)                AS total_size,
           LEAD(ratio) OVER (PARTITION BY platform ORDER BY rn)    AS next_ratio
    FROM headroom
),
-- Candidate rates, one per "the first N strata of this platform are maxed out",
-- plus the hypothesis that none are.
candidates AS (
    SELECT platform,
           0 AS capped_count,
           CASE WHEN total_size > 0 THEN remaining * 1.0 / total_size ELSE 0 END AS lambda,
           0.0 AS ratio_at,
           MIN(ratio) AS next_ratio
    FROM (SELECT platform, ratio, remaining,
                 SUM(n_rows) OVER (PARTITION BY platform) AS total_size
          FROM headroom)
    GROUP BY platform, remaining, total_size
    UNION ALL
    SELECT platform, rn,
           CASE WHEN total_size - cum_size > 0
                THEN (remaining - cum_room) * 1.0 / (total_size - cum_size)
                ELSE 1e18 END,
           ratio,
           COALESCE(next_ratio, 1e18)
    FROM running
),
solution AS (
    SELECT platform, lambda
    FROM (SELECT platform, lambda,
                 ROW_NUMBER() OVER (PARTITION BY platform ORDER BY capped_count) AS pick
          FROM candidates
          WHERE ratio_at <= lambda AND lambda < next_ratio)
    WHERE pick = 1
),
raw AS (
    SELECT h.platform, h.stratum, h.n_rows, h.seed, h.room, h.floor_kept, h.quota,
           h.seed + CASE WHEN h.ratio <= sol.lambda
                         THEN h.room * 1.0
                         ELSE sol.lambda * h.n_rows END AS exact
    FROM headroom h
    JOIN solution sol ON sol.platform = h.platform
),
floored AS (
    SELECT platform, stratum, n_rows, seed, room, floor_kept, quota, exact,
           MIN(CAST(exact AS INTEGER), n_rows)                    AS whole,
           exact - CAST(exact AS INTEGER)                         AS frac
    FROM raw
),
ranked AS (
    SELECT platform, stratum, n_rows, floor_kept, whole, frac,
           quota - SUM(whole) OVER (PARTITION BY platform)        AS shortfall,
           ROW_NUMBER() OVER (
               PARTITION BY platform
               ORDER BY CASE WHEN whole < n_rows THEN 0 ELSE 1 END, frac DESC, stratum
           ) AS rank_
    FROM floored
)
SELECT platform,
       stratum,
       n_rows,
       whole + CASE WHEN whole < n_rows AND rank_ <= shortfall THEN 1 ELSE 0 END,
       floor_kept
FROM ranked;
