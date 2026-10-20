# stratified-sql

**Stratified sampling with caps, floors, and design-based weighted estimates —
in SQL, with no loops and no dataframe library.**

Standard library only. Python 3.11+. `python corpus.py && python run.py` works
immediately after cloning, with no network, no keys, and no data download.

---

## The problem

You have a corpus of 60,000 documents and the budget to annotate 7,000. You
cannot take a simple random sample, because one platform is 63% of the corpus
and would swamp the sample, leaving the other five too thin to say anything
about. So you cap it. And you put a floor under each cell, because a stratum
holding 300 rows that gets handed 2 is a stratum you have paid for and cannot
use.

Both decisions are correct, and both break the sample.

A capped, floored sample is no longer a miniature of the corpus. The plain mean
of any column in it is now a statement about the sample and nothing else. On the
synthetic corpus in this repo, the gap is not subtle:

```
unweighted sample mean      0.2266   <- describes the sample
weighted estimate           0.1589  +/- 0.0065
true corpus prevalence      0.1593
```

**42% relative error, in the direction that flatters whatever you were hoping to
find.** Nothing warns you. The number looks fine, the sample is large, the code
ran without complaint.

The fix is not complicated — every sampled row has to carry the number of corpus
rows it stands in for, and every corpus-level claim has to use it. The fix is
just *never applied*, because by the time anyone computes a percentage the
sampling design is three scripts away and the weight column got dropped in a
`SELECT` somewhere.

This repo keeps the design and the estimate in the same place: both in SQL,
against the same tables.

---

## What it does

| | |
|---|---|
| **Allocation** | Splits a draw across platforms with a per-platform cap, then across strata with a per-stratum floor. Exact integers — the draw lands on 7,000, not near it. |
| **Capped redistribution** | When a cap binds, the quota it cannot use flows to the others. Closed form, not a loop: see below. |
| **The draw** | Systematic over topic order inside each stratum, so a cell cannot come back as one topic repeated. |
| **Weights** | `n_rows / n_draw` per stratum — the inverse sampling fraction. |
| **Estimates** | Stratified mean with design-based variance, finite population correction, 95% CI, and the design effect. |

Run it:

```
python corpus.py     # writes corpus.csv (synthetic, deterministic)
python run.py        # runs every file in sql/ in order, prints the report
python -m pytest     # 17 property tests
```

Output on the default 60,000-row corpus:

```
PLATFORM QUOTA  (the cap forces the redistribution)
  platform           corpus     cap   drawn  % corpus  % sample  capped
  video_comments     37,599   2,800   2,800    62.7%     40.0%   yes
  forum_a             8,401   2,800   1,575    14.0%     22.5%   no
  forum_b             5,542   2,800   1,039     9.2%     14.8%   no
  blog_comments       4,250   2,800     797     7.1%     11.4%   no
  qa_site             2,960   2,800     555     4.9%      7.9%   no
  microblog           1,248   1,248     234     2.1%      3.3%   no

  naive error                 0.0673  (+42% relative)
  weighted error              0.0004  (+0% relative)
  design effect               0.58     (stratifying bought precision)
```

---

## The part worth reading: capped allocation without a loop

Spreading a total across keys in proportion to their size is one line. Doing it
when some keys have a ceiling is where people give up and write a `while` loop
in Python, because capping one key frees quota that has to be re-spread among
the others, which may push *them* into their caps.

It does not need a loop. Capped proportional allocation is water-filling: there
is a single rate `lambda` with

```
sum_k min(limit_k, lambda * size_k) = total
```

and the keys whose cap binds are exactly those with `limit_k / size_k <= lambda`.
So order the keys by that ratio, and **the capped set is always a prefix of that
order**. Walk the prefixes with a running total, and each one gives a candidate
`lambda` in closed form. The right one is the self-consistent prefix: every key
it assumes is capped really is, and the next one really is not.

That is three window functions and no iteration — [`sql/03_quota_platform.sql`](sql/03_quota_platform.sql).
The same machinery runs again per platform, with floors taken off the top, in
[`sql/04_quota_stratum.sql`](sql/04_quota_stratum.sql).

Integer exactness is a separate problem and gets the standard answer: take the
floor of each real-valued share, then hand the shortfall to the largest
fractional parts, skipping anything already at its ceiling.

### Systematic sampling is also one window function

Taking `n` rows from a stratum of `N` without clustering on one topic:

```sql
bucket = CAST((row_number - 1) * n AS INTEGER) / N
```

over rows ordered by `(topic, hash)` cuts the stratum into exactly `n` equal
blocks; taking the first row of each block takes one row per block. No sorting
by random, no `ORDER BY RANDOM() LIMIT n`, and it is reproducible.

### The estimator says what it does not know

```
p_hat = sum_h (N_h / N) * p_h
Var   = sum_h (N_h / N)^2 * (1 - n_h/N_h) * p_h(1 - p_h) / (n_h - 1)
```

The `(1 - n_h/N_h)` term is the finite population correction. A stratum where
you sampled half the rows has far less uncertainty left in it than the binomial
formula assumes, and leaving it out overstates every error bar you publish.

The report prints the **design effect** — this design's variance over the
variance a simple random sample of the same size would have had. Below 1,
stratifying bought precision; above 1, it cost precision, which is the honest
price of the stratum coverage it bought elsewhere. It belongs in the output,
not in a footnote.

---

## Reproducibility

There is no seeded RNG inside the database. Each row carries `hash`, a
deterministic 32-bit value derived from its id, and every shuffle in the SQL
orders by it — the same idea as a content-hash key in an ingestion pipeline.
Two builds of the same corpus produce byte-identical samples, which is asserted
in the tests rather than hoped for.

## The data is synthetic, on purpose

`corpus.py` generates the corpus. It reproduces only the *structure* that makes
weighting matter: one platform dominating, strata of wildly different sizes,
and — the part that does the damage — an outcome whose prevalence varies by
stratum. If prevalence were flat, weighting would change nothing and none of
this would be worth writing.

It also means `run.py` can print the true corpus prevalence next to the
estimate, which is the one thing you never get to see in production. The tests
assert the weighted estimate beats the naive one *and* that the naive error
stays above 2%, so the corpus cannot quietly stop exercising the bias.

## Where it came from

The design is distilled from the sampling layer of an annotation pipeline over
public social-media text — six sources, one dominant, a six-field schema, and a
budget that covered a fraction of the corpus. In that implementation the
weights are computed in pandas and written onto every sampled row, and the rule
for using them is written down — corpus-level claims weighted, model metrics
not. Nothing downstream reads the column yet. This repo is the half that was
specified and never built, written in the place the data already lives.

## Licence

MIT.
