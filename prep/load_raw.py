"""Load raw CSV + XLSX into DuckDB as raw_assessments and raw_enrollment.

Run from the project root:
    .venv/Scripts/python prep/load_raw.py
"""
from pathlib import Path
import duckdb
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / "duckdb" / "csgf.duckdb"
CSV_PATH = ROOT / "raw" / "2025_academic_achievement.csv"
XLSX_PATH = ROOT / "raw" / "ORR_enrollment_2024-25.xlsx"

for src in (CSV_PATH, XLSX_PATH):
    if not src.exists():
        raise FileNotFoundError(f"Source file missing: {src}")

DB_PATH.parent.mkdir(parents=True, exist_ok=True)
con = duckdb.connect(str(DB_PATH))

# Assessment: native DuckDB CSV reader. sample_size=-1 scans the full file
# so DuckDB doesn't misinfer a column type from a non-representative head.
con.execute(f"""
    CREATE OR REPLACE TABLE raw_assessments AS
    SELECT * FROM read_csv_auto('{CSV_PATH.as_posix()}',
                                header=true,
                                sample_size=-1)
""")

# Enrollment: pandas reads the XLSX (DuckDB's spatial st_read for XLSX is
# unreliable on Windows). The "School Totals by Grade" sheet has one row
# per school, with grade columns going wide.
df = pd.read_excel(XLSX_PATH, sheet_name="School Totals by Grade")
con.register("enrollment_df", df)
con.execute("CREATE OR REPLACE TABLE raw_enrollment AS SELECT * FROM enrollment_df")

# Quick sanity logging
n_assess = con.execute("SELECT COUNT(*) FROM raw_assessments").fetchone()[0]
n_enroll = con.execute("SELECT COUNT(*) FROM raw_enrollment").fetchone()[0]
print(f"raw_assessments: {n_assess:,} rows")
print(f"raw_enrollment:  {n_enroll:,} rows")

con.close()
