-- What the sample says about the corpus — and what it says if you forget the
-- weights.
--
-- The design over-samples small platforms and long posts on purpose. That is
-- the right call for annotation: it buys usable counts in the strata that would
-- otherwise be too thin to learn anything from. It also means the sample is no
-- longer a miniature of the corpus, so the plain mean of a sampled column is a
-- statement about the sample and nothing else.
--
-- The stratified estimator puts the corpus back:
--
--   p_hat   = sum_h (N_h / N) * p_h
--   Var     = sum_h (N_h / N)^2 * (1 - n_h/N_h) * p_h(1 - p_h) / (n_h - 1)
--
-- The (1 - n_h/N_h) term is the finite population correction: a stratum where
-- half the rows were sampled has far less uncertainty left in it than the
-- binomial formula assumes, and ignoring that overstates every error bar.
--
-- `design_effect` is the variance of this design over the variance a simple
-- random sample of the same size would have had. Above 1 means the stratified
-- design cost precision on this quantity — which is the honest price of the
-- coverage it bought elsewhere, and worth printing rather than hiding.

DROP VIEW IF EXISTS stratum_estimates;
CREATE VIEW stratum_estimates AS
SELECT
    s.stratum,
    s.platform,
    q.n_rows                                   AS n_corpus,
    COUNT(*)                                   AS n_sample,
    AVG(s.outcome)                             AS p_hat,
    COUNT(*) * 1.0 / q.n_rows                  AS sampling_fraction,
    MAX(s.weight)                              AS weight
FROM sample s
JOIN quota q ON q.stratum = s.stratum
GROUP BY s.stratum, s.platform, q.n_rows;

DROP VIEW IF EXISTS corpus_estimate;
CREATE VIEW corpus_estimate AS
WITH totals AS (
    SELECT SUM(n_rows) AS n_corpus FROM stratum_sizes
),
parts AS (
    SELECT e.n_corpus * 1.0 / t.n_corpus                    AS share,
           e.p_hat,
           e.n_sample,
           e.n_corpus,
           e.sampling_fraction
    FROM stratum_estimates e, totals t
),
agg AS (
    SELECT
        SUM(share * p_hat)                                  AS p_weighted,
        SUM(CASE WHEN n_sample > 1
                 THEN share * share
                      * (1.0 - sampling_fraction)
                      * p_hat * (1.0 - p_hat) / (n_sample - 1)
                 ELSE 0.0 END)                              AS variance,
        SUM(n_sample)                                       AS n_sample
    FROM parts
)
SELECT
    (SELECT AVG(outcome) FROM sample)                       AS p_naive,
    p_weighted,
    sqrt(variance)                                          AS se,
    p_weighted - 1.96 * sqrt(variance)                      AS ci_low,
    p_weighted + 1.96 * sqrt(variance)                      AS ci_high,
    n_sample,
    CASE WHEN p_weighted > 0 AND p_weighted < 1 AND n_sample > 0
         THEN variance / (p_weighted * (1.0 - p_weighted) / n_sample)
         END                                                AS design_effect,
    -- Only computable because this corpus is synthetic. In production the
    -- whole point is that you cannot see this column.
    (SELECT AVG(outcome) FROM corpus)                       AS p_truth
FROM agg;
