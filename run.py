"""Build the stratified sample and report what it says about the corpus.

    python corpus.py          # once, writes corpus.csv
    python run.py             # runs every file in sql/ in order, prints the report
    python run.py --db out.db # keep the database instead of using memory

Standard library only. The SQL does the work; this file loads a CSV, runs the
statements in order, and formats the output.
"""
from __future__ import annotations

import argparse
import csv
import sqlite3
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SQL_DIR = HERE / "sql"


def load_corpus(conn: sqlite3.Connection, path: Path) -> int:
    with path.open(newline="", encoding="utf-8") as handle:
        rows = [
            (r["id"], r["platform"], r["type"], int(r["n_words"]),
             int(r["topic"]), int(r["outcome"]), int(r["hash"]))
            for r in csv.DictReader(handle)
        ]
    conn.executemany(
        "INSERT INTO corpus (id, platform, type, n_words, topic, outcome, hash)"
        " VALUES (?, ?, ?, ?, ?, ?, ?)", rows)
    return len(rows)


def run_sql_files(conn: sqlite3.Connection, after_schema=None) -> None:
    for path in sorted(SQL_DIR.glob("*.sql")):
        conn.executescript(path.read_text(encoding="utf-8"))
        if after_schema and path.name.startswith("01_"):
            after_schema()


def rule(title: str) -> None:
    print(f"\n{title}\n" + "-" * len(title))


def report(conn: sqlite3.Connection) -> int:
    conn.row_factory = sqlite3.Row

    target = conn.execute(
        "SELECT value FROM design WHERE key = 'n_draw'").fetchone()[0]
    drawn = conn.execute("SELECT COUNT(*) FROM sample").fetchone()[0]

    rule("PLATFORM QUOTA  (the cap forces the redistribution)")
    print(f"  {'platform':<16}{'corpus':>9}{'cap':>8}{'drawn':>8}"
          f"{'% corpus':>10}{'% sample':>10}  capped")
    corpus_n = conn.execute("SELECT COUNT(*) FROM corpus").fetchone()[0]
    for r in conn.execute(
            "SELECT pq.platform, pq.n_rows, pq.cap, pq.n_draw, pq.capped,"
            "       (SELECT COUNT(*) FROM sample s WHERE s.platform = pq.platform) AS got"
            "  FROM platform_quota pq ORDER BY pq.n_rows DESC"):
        print(f"  {r['platform']:<16}{r['n_rows']:>9,}{r['cap']:>8,}{r['got']:>8,}"
              f"{r['n_rows'] / corpus_n:>9.1%}{r['got'] / max(drawn, 1):>10.1%}"
              f"{'   yes' if r['capped'] else '   no'}")

    rule("STRATUM COVERAGE  (the floor is what keeps the thin cells usable)")
    row = conn.execute(
        "SELECT COUNT(*) AS n_strata,"
        "       SUM(CASE WHEN n_draw = 0 THEN 1 ELSE 0 END) AS empty,"
        "       MIN(n_draw) AS smallest, MAX(n_draw) AS largest,"
        "       SUM(CASE WHEN floor_kept = 0 THEN 1 ELSE 0 END) AS floors_dropped"
        "  FROM quota").fetchone()
    print(f"  strata                {row['n_strata']:>8,}")
    print(f"  drawn from            {row['n_strata'] - row['empty']:>8,}")
    print(f"  smallest / largest    {row['smallest']:>8,} / {row['largest']:,}")
    print(f"  floors dropped        {row['floors_dropped']:>8,}"
          "   (a platform whose quota could not afford them)")

    rule("WEIGHTS")
    w = conn.execute(
        "SELECT MIN(weight) AS lo, MAX(weight) AS hi, SUM(weight) AS total"
        "  FROM sample").fetchone()
    print(f"  range                 {w['lo']:>8.1f} - {w['hi']:,.1f}")
    print(f"  sum of weights        {w['total']:>8,.0f}   "
          f"(should land on the corpus size, {corpus_n:,})")

    rule("THE ESTIMATE  (what the sample says about the corpus)")
    e = conn.execute("SELECT * FROM corpus_estimate").fetchone()
    print(f"  unweighted sample mean      {e['p_naive']:.4f}   <- wrong: this describes the sample")
    print(f"  weighted estimate           {e['p_weighted']:.4f}  "
          f"+/- {1.96 * e['se']:.4f}   95% CI "
          f"[{e['ci_low']:.4f}, {e['ci_high']:.4f}]")
    print(f"  true corpus prevalence      {e['p_truth']:.4f}   <- only visible because this corpus is synthetic")
    print()
    naive_err = abs(e["p_naive"] - e["p_truth"])
    weighted_err = abs(e["p_weighted"] - e["p_truth"])
    print(f"  naive error                 {naive_err:.4f}  ({naive_err / e['p_truth']:+.0%} relative)")
    print(f"  weighted error              {weighted_err:.4f}  ({weighted_err / e['p_truth']:+.0%} relative)")
    effect = e["design_effect"]
    verdict = "stratifying bought precision" if effect < 1 else "the price of stratum coverage"
    print(f"  design effect               {effect:.2f}     ({verdict})")

    covered = e["ci_low"] <= e["p_truth"] <= e["ci_high"]
    print(f"  truth inside the 95% CI     {'yes' if covered else 'NO'}")

    rule("CHECKS")
    ok = True
    for label, got, want in (
            ("sample size == n_draw", drawn, int(target)),
            ("sum of weights == corpus", round(w["total"]), corpus_n),
    ):
        flag = "ok " if got == want else "FAIL"
        ok &= got == want
        print(f"  [{flag}] {label:<28} {got:,} vs {want:,}")
    print(f"  [{'ok ' if covered else 'FAIL'}] truth within CI")
    return 0 if (ok and covered) else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", default="corpus.csv")
    parser.add_argument("--db", default=":memory:")
    args = parser.parse_args()

    corpus_path = Path(args.corpus)
    if not corpus_path.is_absolute():
        corpus_path = HERE / corpus_path
    if not corpus_path.exists():
        print(f"no {corpus_path.name}; run `python corpus.py` first", file=sys.stderr)
        return 2

    if args.db != ":memory:":
        Path(args.db).unlink(missing_ok=True)
    conn = sqlite3.connect(args.db)
    try:
        run_sql_files(conn, after_schema=lambda: load_corpus(conn, corpus_path))
        return report(conn)
    finally:
        conn.commit()
        conn.close()


if __name__ == "__main__":
    raise SystemExit(main())
