"""End-to-end verification: prints PASS/FAIL on every key invariant.

Run from the project root after `dbt build`:
    .venv/Scripts/python scripts/verify.py
"""
from pathlib import Path
import duckdb

DB = Path(__file__).resolve().parent.parent / "duckdb" / "csgf.duckdb"
con = duckdb.connect(str(DB), read_only=True)

results = []  # (label, passed, detail)


def check(label: str, ok: bool, detail: str = "") -> None:
    results.append((label, ok, detail))
    mark = "PASS" if ok else "FAIL"
    print(f"[{mark}] {label}" + (f"  ->{detail}" if detail else ""))


# ---------------------------------------------------------------------------
# 1. Tables exist
# ---------------------------------------------------------------------------
print("\n--- 1. Tables/views exist ---")
existing = {row[0] for row in con.execute(
    "SELECT table_name FROM information_schema.tables WHERE table_schema='main'"
).fetchall()}

for t in [
    "raw_assessments",
    "raw_enrollment",
    "stg_assessments",
    "stg_enrollment",
    "int_enrollment_long",
    "int_school_subject_grade",
    "school_subject_proficiency",
]:
    check(f"table/view present: {t}", t in existing)


# ---------------------------------------------------------------------------
# 2. Row counts
# 252,957 / 1,780 are file-fingerprints (specific to the SY 2024-25 source
# files we loaded), not pipeline invariants. A miss here means "different
# input file," not a pipeline bug. The mart > 2,000 check is the structural
# invariant.
# ---------------------------------------------------------------------------
print("\n--- 2. Row counts ---")
ra = con.execute("SELECT COUNT(*) FROM raw_assessments").fetchone()[0]
re_ = con.execute("SELECT COUNT(*) FROM raw_enrollment").fetchone()[0]
mart = con.execute("SELECT COUNT(*) FROM school_subject_proficiency").fetchone()[0]

check("raw_assessments has 252,957 rows (file fingerprint)", ra == 252957, f"got {ra:,}")
check("raw_enrollment has 1,780 rows (file fingerprint)",    re_ == 1780, f"got {re_:,}")
check("mart has > 2,000 rows",                               mart > 2000, f"got {mart:,}")


# ---------------------------------------------------------------------------
# 3. Mart grain — must be unique on (school_code, subject)
# ---------------------------------------------------------------------------
print("\n--- 3. Mart grain ---")
n, uniq = con.execute(
    "SELECT COUNT(*), COUNT(DISTINCT school_code || subject) FROM school_subject_proficiency"
).fetchone()
check("mart unique on (school_code, subject)", n == uniq, f"{n} rows / {uniq} unique")


# ---------------------------------------------------------------------------
# 4. Suppression flag has all 4 expected values
# ---------------------------------------------------------------------------
print("\n--- 4. Suppression flag values ---")
flags = {row[0] for row in con.execute(
    "SELECT DISTINCT suppression_flag FROM school_subject_proficiency"
).fetchall()}
expected_flags = {"Complete", "Partial", "Severely Suppressed", "No Data"}
check("all 4 tiers present", flags == expected_flags, f"got {sorted(flags)}")


# ---------------------------------------------------------------------------
# 5. pct_proficient invariants
# ---------------------------------------------------------------------------
print("\n--- 5. pct_proficient invariants ---")
oob = con.execute("""
    SELECT COUNT(*) FROM school_subject_proficiency
    WHERE pct_proficient < 0 OR pct_proficient > 100
""").fetchone()[0]
check("0 <= pct_proficient <= 100",       oob == 0, f"{oob} out-of-range")

null_violations = con.execute("""
    SELECT COUNT(*) FROM school_subject_proficiency
    WHERE (suppression_flag = 'No Data' AND pct_proficient IS NOT NULL)
       OR (suppression_flag != 'No Data' AND pct_proficient IS NULL)
""").fetchone()[0]
check("pct_proficient NULL iff suppression_flag = 'No Data'",
      null_violations == 0, f"{null_violations} violations")


# ---------------------------------------------------------------------------
# 6. Suppression flag tier counts approximately match what's documented
# ---------------------------------------------------------------------------
print("\n--- 6. Tier counts (across both subjects) ---")
counts = dict(con.execute("""
    SELECT suppression_flag, COUNT(*) FROM school_subject_proficiency GROUP BY 1
""").fetchall())
print(f"  Complete:            {counts.get('Complete', 0):>5}")
print(f"  Partial:             {counts.get('Partial', 0):>5}")
print(f"  Severely Suppressed: {counts.get('Severely Suppressed', 0):>5}")
print(f"  No Data:             {counts.get('No Data', 0):>5}")
check("Complete is the largest tier",
      counts.get("Complete", 0) == max(counts.values()))
check("Severely Suppressed < Partial < Complete",
      counts.get("Severely Suppressed", 0) < counts.get("Partial", 0)
      < counts.get("Complete", 0))


# ---------------------------------------------------------------------------
# 7. Join-key sanity — most enrollment schools should match assessments
# ---------------------------------------------------------------------------
print("\n--- 7. Join-key sanity ---")
e_schools, matched = con.execute("""
    SELECT COUNT(DISTINCT e.school_code),
           COUNT(DISTINCT CASE WHEN a.school_code IS NOT NULL THEN e.school_code END)
    FROM stg_enrollment e
    LEFT JOIN stg_assessments a
      ON a.school_code = e.school_code AND a.agency_type = 'School'
""").fetchone()
match_pct = 100.0 * matched / e_schools if e_schools else 0
check(">=95% enrollment schools match assessments",
      match_pct >= 95, f"{matched}/{e_schools} = {match_pct:.1f}%")


# ---------------------------------------------------------------------------
# 8. school_code length is exactly 9 (compound key contract)
# ---------------------------------------------------------------------------
print("\n--- 8. Join-key length contract ---")
bad_len = con.execute("""
    SELECT COUNT(*) FROM stg_enrollment WHERE LENGTH(school_code) != 9
""").fetchone()[0]
check("all stg_enrollment.school_code are 9 chars", bad_len == 0,
      f"{bad_len} bad lengths")


# ---------------------------------------------------------------------------
# 9. Spot-check a known Complete school (large enrollment)
# ---------------------------------------------------------------------------
print("\n--- 9. Spot-check JENKS MS (large school, expect Complete) ---")
jenks = con.execute("""
    SELECT subject, suppression_flag, grades_with_data, grades_in_universe,
           ROUND(pct_proficient, 1) AS pct
    FROM school_subject_proficiency
    WHERE school_name = 'JENKS MS'
    ORDER BY subject
""").fetchall()
for row in jenks:
    print(f"  {row}")
check("JENKS MS has 2 rows (ELA + Math)", len(jenks) == 2)
check("JENKS MS is Complete on both subjects",
      all(r[1] == "Complete" for r in jenks))


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print("\n" + "=" * 60)
n_passed = sum(1 for _, ok, _ in results if ok)
n_total = len(results)
print(f"{n_passed}/{n_total} checks passed")
print("=" * 60)

con.close()
exit(0 if n_passed == n_total else 1)
