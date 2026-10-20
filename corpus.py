"""Generate a synthetic corpus with the shape that makes weighting matter.

    python corpus.py            # writes corpus.csv (60,000 rows)
    python corpus.py --rows 5000

No real data is used or shipped. The generator reproduces only the *structure*
that forces a design-based estimator: one platform dominating the corpus, strata
of very different sizes, and — the part that does the damage — an outcome whose
prevalence varies by stratum. If prevalence were flat, weighting would change
nothing and none of this would be worth writing.

Every row carries `hash`, a deterministic 32-bit value derived from `id`. The SQL
orders by it wherever a shuffle is needed, so the pipeline is reproducible
without a seeded RNG in the database — the same trick as a content-hash key in
an ingestion pipeline.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import random

# Platform mix: one platform owns most of the corpus, four are small. This is
# the whole reason a cap exists in the allocation step.
PLATFORMS = [
    ("video_comments", 0.63),
    ("forum_a", 0.14),
    ("forum_b", 0.09),
    ("blog_comments", 0.07),
    ("qa_site", 0.05),
    ("microblog", 0.02),
]

TYPES = [("post", 0.38), ("reply", 0.47), ("comment", 0.15)]

N_TOPICS = 33
OUTLIER_SHARE = 0.109          # rows BERTopic leaves unassigned, as topic -1

# Mean words per (platform, type). Long-form forums vs one-line video comments:
# this is what spreads rows across the length bins unevenly.
MEAN_WORDS = {
    ("video_comments", "post"): 32, ("video_comments", "reply"): 14,
    ("video_comments", "comment"): 11,
    ("forum_a", "post"): 180, ("forum_a", "reply"): 70, ("forum_a", "comment"): 45,
    ("forum_b", "post"): 150, ("forum_b", "reply"): 60, ("forum_b", "comment"): 40,
    ("blog_comments", "post"): 90, ("blog_comments", "reply"): 55,
    ("blog_comments", "comment"): 38,
    ("qa_site", "post"): 120, ("qa_site", "reply"): 65, ("qa_site", "comment"): 30,
    ("microblog", "post"): 22, ("microblog", "reply"): 12, ("microblog", "comment"): 10,
}

# P(outcome = 1) by platform and by length bin. The gradient is the point: long
# forum posts describe the outcome far more often than one-line video comments,
# and the long forum strata are exactly the ones a capped design over-samples.
P_BY_PLATFORM = {
    "video_comments": 0.06, "forum_a": 0.41, "forum_b": 0.36,
    "blog_comments": 0.19, "qa_site": 0.24, "microblog": 0.08,
}
P_BY_LENGTH = {"short": 0.55, "medium": 1.00, "long": 1.45}   # multiplicative

SHORT_MAX, MEDIUM_MAX = 25, 100
SEED = 5703


def pick(weighted: list[tuple[str, float]], rng: random.Random) -> str:
    roll, acc = rng.random(), 0.0
    for name, share in weighted:
        acc += share
        if roll < acc:
            return name
    return weighted[-1][0]


def length_bin(n_words: int) -> str:
    if n_words <= SHORT_MAX:
        return "short"
    if n_words <= MEDIUM_MAX:
        return "medium"
    return "long"


def row_hash(row_id: str) -> int:
    """Deterministic 32-bit key. Stable across machines and Python versions."""
    return int.from_bytes(hashlib.sha256(row_id.encode()).digest()[:4], "big")


def generate(n_rows: int) -> list[dict]:
    rng = random.Random(SEED)
    rows = []
    for i in range(n_rows):
        platform = pick(PLATFORMS, rng)
        type_ = pick(TYPES, rng)

        mean = MEAN_WORDS[(platform, type_)]
        n_words = max(1, int(rng.lognormvariate(0, 0.8) * mean))
        bin_ = length_bin(n_words)

        topic = -1 if rng.random() < OUTLIER_SHARE else rng.randrange(N_TOPICS)

        p = min(0.97, P_BY_PLATFORM[platform] * P_BY_LENGTH[bin_])
        outcome = 1 if rng.random() < p else 0

        row_id = f"{platform}_{i:06d}"
        rows.append({
            "id": row_id,
            "platform": platform,
            "type": type_,
            "n_words": n_words,
            "topic": topic,
            "outcome": outcome,
            "hash": row_hash(row_id),
        })
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rows", type=int, default=60_000)
    parser.add_argument("--out", default="corpus.csv")
    args = parser.parse_args()

    rows = generate(args.rows)
    with open(args.out, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    true_rate = sum(r["outcome"] for r in rows) / len(rows)
    print(f"wrote {args.out}: {len(rows):,} rows")
    print(f"true corpus prevalence: {true_rate:.4f}  "
          f"(the number the weighted estimate has to recover)")


if __name__ == "__main__":
    main()
