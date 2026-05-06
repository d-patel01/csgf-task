# CSGF Analytics Engineer — Performance Task

A small data pipeline that loads Oklahoma 2024–25 school assessment + enrollment data into DuckDB, builds a dbt model at school×subject grain (% proficient grades 3–8 for ELA and Math, with a 4-tier suppression flag), and produces the analysis writeup.

The full analysis — methodology decisions, suppression findings, recommendation, and performance summary — lives in **[`analysis.md`](analysis.md)**.

## Prerequisites

- Python 3.10+
- The two raw data files already placed in `raw/`:
  - `2025_academic_achievement.csv`
  - `ORR_enrollment_2024-25.xlsx`

## Setup

```bash
# from the project root
python -m venv .venv
.venv/Scripts/pip install -r requirements.txt   # Windows
# or: .venv/bin/pip install -r requirements.txt  # macOS/Linux
```

`requirements.txt` pins `duckdb`, `dbt-duckdb`, `pandas`, and `openpyxl`.

## Run the pipeline

All three steps below should be run sequentially from the project root. `DBT_PROFILES_DIR=.` tells dbt to read `profiles.yml` from the current directory rather than `~/.dbt/`.

```bash
# Step 1: Load raw CSV + XLSX into DuckDB raw_* tables (run from project root)
.venv/Scripts/python prep/load_raw.py

# Step 2: Install dbt packages and run all models + tests (run from dbt_project)
cd dbt_project
DBT_PROFILES_DIR=. ../.venv/Scripts/dbt deps
DBT_PROFILES_DIR=. ../.venv/Scripts/dbt build
cd ..

# Step 3: Run the suppression analysis (numbers cited in analysis.md)
.venv/Scripts/python analysis/suppression_analysis.py
```

Cross-platform tip: on macOS/Linux replace `.venv/Scripts/` with `.venv/bin/`.

## Project structure

```
csgf-ok-task/
├── CLAUDE.md                  Project context + behavioral guidelines
├── analysis.md                Deliverable writeup (data prep notes, suppression
│                              analysis, performance summary, AI use notes)
├── README.md                  This file
├── .gitignore                 target/, dbt_packages/, __pycache__/, .venv/
├── requirements.txt           Pinned Python deps
│
├── raw/                       Source data files (input)
│   ├── 2025_academic_achievement.csv
│   └── ORR_enrollment_2024-25.xlsx
│
├── duckdb/
│   └── csgf.duckdb            Final database with raw + staged + intermediate
│                              + mart tables (the deliverable)
│
├── prep/
│   └── load_raw.py            CSV + XLSX → raw_* tables in csgf.duckdb
│
├── dbt_project/               3-tier dbt project (DuckDB target)
│   ├── dbt_project.yml        Materialization defaults per layer
│   ├── profiles.yml           Local dev profile pointing at csgf.duckdb
│   ├── packages.yml           dbt_utils dependency
│   ├── models/
│   │   ├── sources.yml        Declares raw tables under source 'oklahoma'
│   │   ├── staging/           1:1 with raw, rename + cast (views)
│   │   ├── intermediate/      Joins, filters, suppression flags (views)
│   │   └── marts/             school_subject_proficiency (table)
│   └── tests/                 Singular tests
│
├── analysis/
│   └── suppression_analysis.py    Computes the numbers cited in analysis.md
│
└── scripts/
    └── verify.py                  End-to-end smoke test (20 invariants).
                                   Run after `dbt build` to confirm everything
                                   matches the documented behavior.
```

## The dbt models at a glance

| Layer | Model | What it does |
|---|---|---|
| staging | `stg_assessments` | 1:1 with raw_assessments — rename + surface raw values. |
| staging | `stg_enrollment` | 1:1 with raw_enrollment + builds compound join key (`District Code \|\| School Code`). |
| intermediate | `int_enrollment_long` | Wide → long: one row per (school × grade) with enrollment > 0. The "should-have-data" universe. |
| intermediate | `int_school_subject_grade` | LEFT JOIN universe ⨝ assessments. Surfaces structural and explicit suppression flags. |
| **marts** | **`school_subject_proficiency`** | **The deliverable.** One row per (school × subject) with weighted % proficient and 4-tier flag. |

11 dbt tests cover: not_null + unique on the staging join key, grain uniqueness on intermediate and mart (`dbt_utils.unique_combination_of_columns`), accepted_values on `subject` and `suppression_flag`, accepted_range on `pct_proficient`, plus a singular test asserting `pct_proficient IS NULL ⟺ suppression_flag = 'No Data'`.

## AI tool use

Claude Code (the CLI) was the primary coding assistant. See **[`analysis.md` § 6](analysis.md#6-ai-tool-use)** for:
- Where it helped (scaffolding boilerplate, DuckDB syntax, XLSX inspection without openpyxl, doc phrasing)
- One decision I made differently — **enrollment-weighted aggregation** instead of the simple `AVG(pct_proficient)` Claude proposed
- One output I verified and corrected — Claude initially mapped `% proficient` to `IndicatorValue`, which is the OK A–F school-grading score, not proficiency. The correct definition is `Advanced + Proficient`.
