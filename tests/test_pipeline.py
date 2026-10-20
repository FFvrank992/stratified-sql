"""The properties the design claims, asserted against a built sample.

Everything here is deterministic: the corpus generator is seeded and the SQL
shuffles by a hash of the row id, so a failure is a real regression rather than
an unlucky draw.
"""
from __future__ import annotations

import sqlite3
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import corpus  # noqa: E402
import run     # noqa: E402

N_ROWS = 20_000


def build(rows: int = N_ROWS) -> sqlite3.Connection:
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    generated = corpus.generate(rows)
    for path in sorted((ROOT / "sql").glob("*.sql")):
        conn.executescript(path.read_text(encoding="utf-8"))
        if path.name.startswith("01_"):
            conn.executemany(
                "INSERT INTO corpus (id, platform, type, n_words, topic, outcome, hash)"
                " VALUES (:id, :platform, :type, :n_words, :topic, :outcome, :hash)",
                generated)
    return conn


@pytest.fixture(scope="module")
def db() -> sqlite3.Connection:
    conn = build()
    yield conn
    conn.close()


def scalar(conn, sql, *args):
    return conn.execute(sql, args).fetchone()[0]


# ---------- allocation ----------

def test_sample_size_is_exact(db):
    """Rounding must not leak. The draw lands on n_draw, not near it."""
    target = scalar(db, "SELECT value FROM design WHERE key = 'n_draw'")
    assert scalar(db, "SELECT COUNT(*) FROM sample") == target


def test_no_platform_exceeds_its_cap(db):
    over = db.execute(
        "SELECT platform, n_draw, cap FROM platform_quota WHERE n_draw > cap"
    ).fetchall()
    assert not over, [dict(r) for r in over]


def test_cap_actually_binds(db):
    """If nothing were capped the test above would be vacuous."""
    assert scalar(db, "SELECT COUNT(*) FROM platform_quota WHERE capped = 1") >= 1


def test_platform_quotas_sum_to_total(db):
    target = scalar(db, "SELECT value FROM design WHERE key = 'n_draw'")
    assert scalar(db, "SELECT SUM(n_draw) FROM platform_quota") == target


def test_stratum_quotas_sum_to_platform_quota(db):
    mismatches = db.execute(
        "SELECT q.platform, SUM(q.n_draw) AS got, pq.n_draw AS want"
        "  FROM quota q JOIN platform_quota pq ON pq.platform = q.platform"
        " GROUP BY q.platform HAVING got <> want").fetchall()
    assert not mismatches, [dict(r) for r in mismatches]


def test_never_draws_more_rows_than_a_stratum_has(db):
    over = db.execute("SELECT stratum FROM quota WHERE n_draw > n_rows").fetchall()
    assert not over, [r["stratum"] for r in over]


def test_floor_is_honoured_where_affordable(db):
    """Every stratum gets min(floor, its size) unless its platform could not pay."""
    floor = scalar(db, "SELECT value FROM design WHERE key = 'min_per_stratum'")
    short = db.execute(
        "SELECT stratum, n_rows, n_draw FROM quota"
        " WHERE floor_kept = 1 AND n_draw < MIN(?, n_rows)", (floor,)).fetchall()
    assert not short, [dict(r) for r in short]


# ---------- the draw ----------

def test_each_stratum_delivers_its_quota(db):
    mismatches = db.execute(
        "SELECT q.stratum, q.n_draw AS want, COUNT(s.id) AS got"
        "  FROM quota q LEFT JOIN sample s ON s.stratum = q.stratum"
        " GROUP BY q.stratum, q.n_draw HAVING got <> want").fetchall()
    assert not mismatches, [dict(r) for r in mismatches]


def test_draw_spreads_across_topics(db):
    """A systematic draw over topic order must not collapse onto a few topics.

    For strata asked for at least 20 rows, the sample should touch most of the
    topics available to it; taking rows off the top would not.
    """
    rows = db.execute(
        "SELECT s.stratum, COUNT(DISTINCT s.topic) AS sampled_topics,"
        "       q.n_draw,"
        "       (SELECT COUNT(DISTINCT c.topic) FROM corpus_stratified c"
        "         WHERE c.platform || ' | ' || c.type || ' | ' || c.length_bin"
        "               = s.stratum) AS available_topics"
        "  FROM sample s JOIN quota q ON q.stratum = s.stratum"
        " GROUP BY s.stratum HAVING q.n_draw >= 20").fetchall()
    assert rows, "no stratum large enough to judge"
    for r in rows:
        reachable = min(r["n_draw"], r["available_topics"])
        assert r["sampled_topics"] >= 0.7 * reachable, dict(r)


def test_sample_rows_are_distinct(db):
    assert scalar(db, "SELECT COUNT(*) FROM sample") == \
           scalar(db, "SELECT COUNT(DISTINCT id) FROM sample")


# ---------- weights ----------

def test_weights_sum_to_the_sampled_population(db):
    """Each weight says how many corpus rows its row stands for; they must add
    back up to the strata the sample actually covers."""
    covered = scalar(db, "SELECT SUM(n_rows) FROM quota WHERE n_draw > 0")
    assert round(scalar(db, "SELECT SUM(weight) FROM sample")) == covered


def test_weights_are_at_least_one(db):
    assert scalar(db, "SELECT MIN(weight) FROM sample") >= 1.0


# ---------- estimates ----------

def test_weighting_beats_the_naive_mean(db):
    e = db.execute("SELECT * FROM corpus_estimate").fetchone()
    naive_err = abs(e["p_naive"] - e["p_truth"])
    weighted_err = abs(e["p_weighted"] - e["p_truth"])
    assert weighted_err < naive_err
    # If the design did not distort the sample, this repo would have no point.
    assert naive_err > 0.02, "the synthetic corpus no longer exercises the bias"


def test_confidence_interval_covers_the_truth(db):
    e = db.execute("SELECT * FROM corpus_estimate").fetchone()
    assert e["ci_low"] <= e["p_truth"] <= e["ci_high"]


def test_standard_error_is_positive_and_small(db):
    e = db.execute("SELECT * FROM corpus_estimate").fetchone()
    assert 0 < e["se"] < 0.05


# ---------- reproducibility ----------

def test_two_builds_agree(db):
    other = build()
    try:
        a = [r[0] for r in db.execute("SELECT id FROM sample ORDER BY id")]
        b = [r[0] for r in other.execute("SELECT id FROM sample ORDER BY id")]
        assert a == b
    finally:
        other.close()


def test_runner_reports_success(tmp_path, capsys):
    """The end-to-end path a reader actually runs."""
    csv_path = tmp_path / "corpus.csv"
    import csv as csv_mod
    rows = corpus.generate(N_ROWS)
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv_mod.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    assert run.main.__module__ == "run"
    sys.argv = ["run.py", "--corpus", str(csv_path)]
    assert run.main() == 0
    assert "weighted estimate" in capsys.readouterr().out
