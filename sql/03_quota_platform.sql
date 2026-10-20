-- Level 1: split the total draw across platforms, with a cap on each.
--
-- Without a cap the dominant platform takes ~63% of the sample and the small
-- platforms end up too thin to say anything about. With a cap, the quota it
-- cannot use has to flow to the others — and that redistribution is the part
-- people usually give up on and do in pandas.
--
-- It does not need a loop. Capped proportional allocation is water-filling:
-- find the single rate `lambda` such that
--
--     sum_k min(limit_k, lambda * size_k) = total
--
-- Keys whose cap binds are exactly those with limit_k / size_k <= lambda. So
-- order the keys by that ratio, and the capped set is always a prefix of that
-- order. Walking the prefixes with a running total gives lambda in closed form,
-- which is three window functions and no iteration.

DROP TABLE IF EXISTS platform_quota;
CREATE TABLE platform_quota (
    platform TEXT    NOT NULL PRIMARY KEY,
    n_rows   INTEGER NOT NULL,   -- rows this platform has in the corpus
    cap      INTEGER NOT NULL,   -- most it may contribute
    n_draw   INTEGER NOT NULL,   -- rows to draw from it
    capped   INTEGER NOT NULL    -- 1 if the cap bound, 0 if proportional
);

INSERT INTO platform_quota (platform, n_rows, cap, n_draw, capped)
WITH consts AS (
    SELECT (SELECT value FROM design WHERE key = 'n_draw')             AS total,
           (SELECT value FROM design WHERE key = 'max_platform_share') AS max_share
),
sizes AS (
    SELECT s.platform,
           SUM(s.n_rows)                                   AS n_rows,
           MIN(SUM(s.n_rows),
               CAST(c.total * c.max_share AS INTEGER))     AS cap
    FROM stratum_sizes s, consts c
    GROUP BY s.platform
),
-- Order by how tight each cap is. The capped set is a prefix of this order.
ordered AS (
    SELECT platform, n_rows, cap,
           cap * 1.0 / n_rows AS ratio,
           ROW_NUMBER() OVER (ORDER BY cap * 1.0 / n_rows, platform) AS rn
    FROM sizes
),
running AS (
    SELECT rn, platform, n_rows, cap, ratio,
           SUM(cap)    OVER (ORDER BY rn ROWS UNBOUNDED PRECEDING) AS cum_cap,
           SUM(n_rows) OVER (ORDER BY rn ROWS UNBOUNDED PRECEDING) AS cum_size,
           SUM(n_rows) OVER ()                                     AS total_size,
           COUNT(*)    OVER ()                                     AS n_keys,
           LEAD(cap * 1.0 / n_rows) OVER (ORDER BY rn)             AS next_ratio
    FROM ordered
),
-- One candidate lambda per hypothesis "the first `capped_count` keys are capped",
-- including the hypothesis that none of them are.
candidates AS (
    SELECT 0 AS capped_count,
           (SELECT total FROM consts) * 1.0 / (SELECT SUM(n_rows) FROM sizes) AS lambda,
           0.0                                                                AS ratio_at,
           (SELECT MIN(cap * 1.0 / n_rows) FROM sizes)                        AS next_ratio
    UNION ALL
    SELECT rn,
           CASE WHEN total_size - cum_size > 0
                THEN ((SELECT total FROM consts) - cum_cap) * 1.0 / (total_size - cum_size)
                -- every key capped: lambda is irrelevant, nothing is left to spread
                ELSE 1e18 END,
           ratio,
           COALESCE(next_ratio, 1e18)
    FROM running
),
-- The valid hypothesis is the one that is self-consistent: every key assumed
-- capped really is (ratio <= lambda), and the next one really is not.
solution AS (
    SELECT lambda
    FROM candidates
    WHERE ratio_at <= lambda AND lambda < next_ratio
    ORDER BY capped_count
    LIMIT 1
),
-- Real-valued allocation, then the integer part.
raw AS (
    SELECT o.platform, o.n_rows, o.cap, o.ratio,
           CASE WHEN o.ratio <= (SELECT lambda FROM solution)
                THEN o.cap * 1.0
                ELSE (SELECT lambda FROM solution) * o.n_rows END AS exact
    FROM ordered o
),
floored AS (
    SELECT platform, n_rows, cap, ratio, exact,
           CAST(exact AS INTEGER)                    AS whole,
           exact - CAST(exact AS INTEGER)            AS frac
    FROM raw
),
-- Largest remainder: hand the rounding shortfall to the biggest fractions,
-- skipping anything already at its cap. This is what makes the total exact.
ranked AS (
    SELECT platform, n_rows, cap, exact, whole, frac,
           (SELECT total FROM consts) - SUM(whole) OVER () AS shortfall,
           ROW_NUMBER() OVER (
               ORDER BY CASE WHEN whole < cap THEN 0 ELSE 1 END, frac DESC, platform
           ) AS rank_
    FROM floored
)
SELECT platform,
       n_rows,
       cap,
       whole + CASE WHEN whole < cap AND rank_ <= shortfall THEN 1 ELSE 0 END,
       CASE WHEN whole >= cap THEN 1 ELSE 0 END
FROM ranked;
