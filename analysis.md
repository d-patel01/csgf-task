# Oklahoma 2024–25 Proficiency Analysis

This document covers the four sections of the performance task: data preparation notes, dbt model methodology, suppression analysis (with recommendation), and a non-technical performance summary. All numbers are computed from `school_subject_proficiency` (the deliverable mart) by `analysis/suppression_analysis.py`.

> **Note on the year label**: the source CSV is named `2025 - Academic Achievement.csv` and the enrollment file is dated October 1, 2024. These describe the same school year. Oklahoma labels school years by the spring-testing window (SY 2024–25 = "2025"), and the October file is the federal fall-membership snapshot for that same year. There is no mismatch.

---

## 1. Data preparation notes

### Source files

| File | Format | Rows | What it is |
|---|---|---|---|
| `raw/2025_academic_achievement.csv` | CSV | 252,957 | Oklahoma school-level proficiency results, SY 2024–25. One row per (entity × subject × grade × subgroup) including district and state aggregates. |
| `raw/ORR_enrollment_2024-25.xlsx` | XLSX (multi-sheet) | 1,780 schools | OSDE October 1, 2024 enrollment counts by school × grade. We use only the `School Totals by Grade` sheet. |

### Loading mechanics (`prep/load_raw.py`)

- **CSV** loads via DuckDB's native `read_csv_auto` with `sample_size=-1` (full-file scan), avoiding type-misinference on numeric columns.
- **XLSX** loads via pandas (`pandas.read_excel(... sheet_name="School Totals by Grade")`). DuckDB has a `spatial` extension that can read XLSX directly via `st_read`, but it's unreliable on Windows and not worth the risk.

### Structural decisions

- **Subgroup**: filtered to `ReportSubgroup = 'All'`. Each school×subject×grade has many rows in the source — one for the all-students total and one for each demographic subgroup (race, ELL, IEP, economic disadvantage, etc.). Unfiltered, the same students would be double-counted across overlapping subgroups. The "All" row is OSDE's pre-aggregated all-students total.
- **Subjects**: filtered to `IndicatorSubtype IN ('ELA', 'Mathematics')` and renamed `Mathematics → Math`. The file also contains `Composite`, `History`, and `Science`; the task scopes us to ELA and Math.
- **Agency type**: filtered to `EducationAgencyType = 'School'`. The CSV also contains district-level (86,902 rows) and state-level (720 rows) aggregates which we ignore — the school grain is what the task asks for.
- **Grades**: filtered to `'03'`–`'08'`. The file also contains an `'All'` aggregate row and `'HS'` rows; we exclude both.
- **% proficient definition**: `Advanced + Proficient` (the two top performance levels of the four-tier scale `BelowBasic < Basic < Proficient < Advanced`). The CSV's `IndicatorValue` column is *not* a proficiency rate — it's Oklahoma's custom A–F school-grading score. This is an easy column to mistake for the metric; we explicitly do not use it.

### Suppression mechanism in the source (plain-language)

Oklahoma suppresses (omits) assessment results for any (school × subject × grade × subgroup) cell where the underlying student count is small enough that publishing the pass-rate could indirectly identify individual students. Federal privacy rules (FERPA) and OSDE policy generally suppress at n < 10. **In this file, suppression is not flagged with a special marker (`*`, `<10`, `S`, etc.) — suppressed cells are simply absent: the row that would have reported them does not appear.** This is "structural" suppression, and it's invisible if you only look at the assessment file: you'd just see fewer rows than expected, but nothing tells you which combinations are missing or why. To detect it we have to anchor against a separate source-of-truth for "what should exist" — the enrollment file. A school with 12 students enrolled in grade 4 and no grade 4 assessment row is suppressed; a school with 0 students enrolled in grade 4 simply doesn't serve grade 4 and isn't suppressed. The pipeline distinguishes these two cases.

### File quirks worth flagging

- **Compound join key**: enrollment's `School Code` is *not* globally unique (e.g., `105` appears in many districts). Schools are uniquely identified by `District Code || School Code` (9 chars total: 2 county + 4 district + 3 site), which matches the assessment file's `FullCode`. Joining on `School Code` alone would silently produce a cartesian explosion. `stg_enrollment` constructs the compound key as the first column.
- **Enrollment column types**: `School Code` arrives from pandas as `DOUBLE` (because one row has it null), so we cast through `INTEGER → VARCHAR` before zero-padding. Otherwise `CAST(105.0 AS VARCHAR)` produces `"105.0"` and the join breaks.
- **Enrollment column names**: grade columns are `GR 03` through `GR 12`, with a typo `AS GR 11` for grade 11 (which we don't use, but worth flagging for a future maintainer).
- **DuckDB UNPIVOT view-serialization quirk**: an early version of `int_enrollment_long` used `UNPIVOT … INTO NAME … VALUE …` syntax. DuckDB serialized this into a view definition that converted the column references into string literals, so every query against the view failed with a binder error. Switched to explicit `UNION ALL` over the six grade columns. Build worked but interactive queries failed — a real-world DuckDB gotcha worth knowing about.
- **Source freshness**: the sources file declares `oklahoma` without `loaded_at_field` or `freshness:` configuration. Intentional — these are static annual data drops, not real-time ingestion.

---

## 2. dbt model: methodology

### Layering (3-tier)

```
sources (oklahoma.raw_*)
  ↓
staging/        — 1:1 with sources, rename + cast only, no filters or joins. Views.
  ↓
intermediate/   — joins, filters, unpivot, derived flags. Views.
  ↓
marts/          — final aggregations. Tables (the deliverable).
```

The intermediate `int_assessments_relevant` step lives as a CTE inside `int_school_subject_grade.sql` rather than its own file — it would be a single-use, single-source filter, and inlining keeps the project lean without obscuring the logic.

### Aggregation methodology — enrollment-weighted average

For each school × subject:

```
                Σ (grade_pct × grade_enrollment)         only over non-suppressed grades
pct_proficient = ────────────────────────────────
                       Σ (grade_enrollment)
```

This is the "rebuild the implicit student counts" approach: `grade_pct × grade_enrollment` reconstructs the count of proficient students in that grade (because `grade_pct` is itself `proficient_count / tested_count × 100`). Summing those counts, then dividing by total students, recovers the school-wide rate.

Why not a simple per-grade average? Because grade enrollments are uneven. A school with 12 students in grade 3 and 100 in grade 8 should have its grade-8 students contribute 8x as much weight to the school's overall rate as its grade-3 students. Simple average treats them equally — wrong.

October 2024 enrollment is used as the per-grade weight. The strictly-correct weight would be the count of students who actually took the test (some October-enrolled students transfer or are absent on test day), but the source CSV doesn't expose this. October enrollment is a close proxy with a small bias.

### Subject mapping

`Mathematics` → `Math` for cleaner downstream usage. ELA stays as `ELA`. Both values are constrained by `accepted_values` test on the mart.

### Subgroup filter

`ReportSubgroup = 'All'` only. Subgroup-level analysis is out of scope for this mart (and likely far more affected by suppression — see recommendation below).

### Suppression flag — universe-anchored, four tiers

The suppression flag is *not* defined relative to "all 6 grades 3–8." It's defined relative to **grades the school actually serves** (i.e., has enrollment > 0 in, per the October ORR file). This means a high school with grades 9–12 is correctly excluded entirely from the universe rather than being flagged as "missing all of 3–8."

Within the school's served grade range, a grade is "missing" if either:
- **Structural suppression**: no assessment row exists at all for (school, subject, grade) — detected via LEFT JOIN miss against the universe. The dominant form in this file.
- **Explicit suppression**: a row exists but `Advanced` or `Proficient` is null — defensive check that doesn't fire in the 2024–25 data but defends against future drift. (We deliberately do *not* check `IndicatorValue` here; it's the A–F score, not a proficiency component.)

Tiers, applied to (school × subject):

| Tier | Coverage |
|---|---|
| `Complete` | every served grade has data |
| `Partial` | at least one missing grade, but coverage ≥ 50% |
| `Severely Suppressed` | coverage < 50% |
| `No Data` | zero grades have data |

The 50% threshold is an intentional choice, not derived. A finer-grained continuous coverage ratio (`grades_with_data / grades_in_universe`) is also surfaced for any consumer who wants to apply their own threshold.

---

## 3. Suppression analysis

### Extent of suppression (by tier, by subject)

| Suppression flag | ELA (n schools) | Math (n schools) | % of subject |
|---|---:|---:|---:|
| Complete | 897 | 898 | **73.4%** |
| Partial | 79 | 78 | 6.4% |
| Severely Suppressed | 48 | 48 | 3.9% |
| No Data | 199 | 199 | 16.3% |
| **Total** | **1,223** | **1,223** | 100% |

About a quarter of school×subject combinations have at least some suppression — but most of that is `No Data` schools entirely absent from the assessment file, not partial-coverage schools.

### Enrollment-weighted coverage — what fraction of *students* live in a Complete school?

| Suppression flag | Total enrollment (ELA scope) | % of state enrollment |
|---|---:|---:|
| Complete | 272,936 | **89.9%** |
| Partial | 10,608 | 3.5% |
| Severely Suppressed | 5,448 | 1.8% |
| No Data | 14,482 | 4.8% |

**About 90% of Oklahoma students attend a Complete school.** Suppression is heavily concentrated in small schools; large schools rarely have a grade so small that suppression triggers.

### Suppression by school size

| Size bucket (grades 3–8 enrollment) | n schools | % NOT Complete |
|---|---:|---:|
| <50 students | 69 | **94.2%** |
| 50–149 | 419 | 52.0% |
| 150–299 | 442 | 9.7% |
| 300–599 | 205 | 0.0% |
| 600+ | 88 | 0.0% |

Above ~300 students in grades 3–8, every school is `Complete`. Below ~50, almost no school is. This is exactly the behavior FERPA-style suppression rules produce — small cells get protected — and it makes the population of suppressed schools structurally different from non-suppressed schools.

### State-level proficiency two ways — does suppression bias the headline number?

| Subject | All schools (weighted) | Complete-only (weighted) | Δ (pp) |
|---|---:|---:|---:|
| ELA | 25.28% | 25.32% | +0.04 |
| Math | 27.46% | 27.46% | 0.00 |

**The state-level average is essentially unchanged whether you include or exclude suppressed schools** (delta ≈ 0). This is because the 90% of students in Complete schools dominate the weighted mean, and the 10% in Partial/Severely Suppressed/No Data schools have similar enough proficiency rates that they don't pull the average noticeably in either direction.

> *Methodology note*: both columns weight by `enrollment_with_data` (students in non-suppressed grades) — for Complete schools this equals `enrollment_in_universe`; for Partial/Severely Suppressed schools it's the subset of grades that reported. The "all schools" column thus answers *"of all students whose proficiency we can observe, what fraction are proficient?"*. The "Complete-only" column restricts to schools where every served grade reported. Standardizing on `enrollment_in_universe` would require imputing pct_proficient for the suppressed grades, which is the question the writeup is asking — so we compare on observable data only. The 0.04 pp gap means the answer is essentially the same either way.

### Recommendation: does the answer hold regardless of the question?

**No — and the impact varies sharply by question type.**

| Question someone might ask | Suppression's effect | Verdict |
|---|---|---|
| What's Oklahoma's overall % proficient in 2024–25? | Δ between all-schools and Complete-only is **0.04 pp** (ELA) and **0.00 pp** (Math). | **Usable.** Answer state averages from this data. |
| How does School A compare to School B? | If either school is Partial or Severely Suppressed, the comparison is fundamentally lossy — you're comparing apples to a fraction of an orange. | **Limited.** OK for Complete-vs-Complete; otherwise misleading. |
| How are small/rural schools doing? | Suppression is concentrated *exactly* in small schools (94% of <50-student schools are not Complete). Any analysis that needs small-school visibility is systematically blinded. | **NOT usable.** This data cannot answer it. |
| How are economically disadvantaged students doing? (or any subgroup) | Subgroup suppression is even more aggressive than All-students suppression — small-n thresholds apply per subgroup. We didn't build a subgroup mart, but the structural suppression here would be far more severe. | **NOT usable** without a separately-modeled subgroup analysis acknowledging the same pattern. |

**Summary**: this dataset answers state-aggregate questions reliably and answers cross-school-rank questions only between Complete schools. It cannot answer small-school questions or subgroup questions in a way that's representative.

### Reasoning

The recommendation is asymmetric because suppression is asymmetric. It systematically removes small cells, which:
1. By weight (enrollment) are a small share of the state — so weighted state averages are robust.
2. By count (number of schools) are a meaningful share — so any analysis that treats schools as the unit of analysis is biased toward larger schools.
3. By population (which schools fall under suppression) is non-random — small/rural/specialized schools, and demographic minorities within any school. So any analysis whose research question is about those populations is systematically blinded.

The state-level delta of 0.04 pp is the data-supported piece of evidence backing the "usable for state averages" claim. Absent that number we'd be asserting; with it, we're observing.

---

## 4. Performance summary (non-technical)

### Distribution of school proficiency in Oklahoma, 2024–25

Looking at the 1,024 schools with usable proficiency data (Complete + Partial), the school-level rate (% of students at Proficient or above) is distributed like this:

| | ELA | Math |
|---|---:|---:|
| 10th percentile | 9.5% | 8.5% |
| 25th percentile | 16.2% | 15.6% |
| **Median** | **23.9%** | **26.5%** |
| 75th percentile | 32.6% | 39.0% |
| 90th percentile | 41.0% | 50.5% |
| Mean | 25.0% | 28.2% |
| Min – Max | 0% – 73% | 0% – 76% |

**Plain-language framing for a non-technical reader:**

> About **half** of Oklahoma elementary and middle schools have **fewer than one in four** students reading at grade level (the median ELA rate is 23.9%). The other half are above that, but only the top 10% of schools clear ~40% proficiency. **Math is slightly higher and considerably wider** — the typical school sits around 26%, but the top 10% reach 50% or more. School-level proficiency varies enormously: a few schools have nearly nobody at grade level, while a handful clear 70%.

### What I would walk a non-technical audience through (and why)

1. **A histogram of school-level proficiency rates**, one for ELA and one for Math, with the median marked. The shape — a long left tail, a peak around 20–30%, and a thin right tail — communicates "most schools are clustered low; a few are much higher" much faster than any number does.
2. **Three example schools**: a top performer, a school at the actual median, and a school at the bottom — each with the actual % proficient. This grounds the abstract distribution in concrete schools the audience may know:

| Position | School | District | ELA % proficient |
|---|---|---|---:|
| Top | CLEGERN ES | EDMOND | 70.3% |
| Median (≈23.9%) | SILO ES | SILO | 23.9% |
| Bottom | WHITMAN ES | TULSA | 0.0% |

3. **The 90% coverage line**: that despite the suppression in the data, ~9 in 10 OK students are accounted for in the headline number — so state-level claims are trustworthy.

4. **One thing I would *not* show a non-technical audience**: a school-by-school ranking. The combination of suppression (~25% of schools missing or partial) and very small school sizes for many of the rest makes a ranking misleading at best.

### Caveats for non-technical readers

- **What "Proficient" means here**: this is Oklahoma's state-defined cut score on the OSTP/OSAS assessment. It is *not* the same as "on track for college" — Oklahoma's cut scores are generally lower than NAEP's "Proficient" or college-readiness benchmarks. A 30% rate on this metric does not mean only 30% of those students will succeed in college.
- **Single year, no trend**: this is one snapshot of SY 2024–25. It does not show whether schools are improving or declining.
- **Suppression skews toward small/rural schools**: 94% of schools with fewer than 50 students in grades 3–8 are not Complete. The distribution shown above is *mostly* a picture of Oklahoma's larger, suburban, and urban schools — it does not represent its smallest and most rural schools well.
- **"2025" file label**: the file name says 2025 but the data is for school year 2024–25 (Oklahoma labels by the spring testing window).
- **Subject vs Composite differences**: this analysis is ELA and Math only. Science and History are also tested but excluded by the task scope. A school that looks low here may look different on Composite.

---

## 5. What I prioritized in 2 hours and what I cut

**Prioritized:**
- Getting a defensible compound join key (single biggest correctness risk in this pipeline)
- 3-tier dbt layering with tests where they catch bugs (`unique_combination_of_columns` on the mart grain and intermediate, `accepted_range`, `accepted_values`, plus a singular test for `pct_proficient IS NULL ⟺ suppression_flag = 'No Data'`)
- The state-level delta calculation that turns the recommendation from assertion into evidence
- Documentation of *why* (aggregation choice, suppression flag definition, IndicatorValue vs Advanced+Proficient)

**Cut:**
- **Quarto rendering** — markdown is acceptable per the task brief, and Quarto adds setup overhead.
- **Subgroup-level mart** — would be the natural next iteration; mentioned in the recommendation rather than built.
- **Distribution chart artifact** — described in §4 rather than rendered. The task explicitly allows description over a built artifact.
- **A `dbt_utils.expression_is_true` test** for the `pct_proficient IS NULL ⟺ No Data` invariant — replaced with a singular test which expresses the same idea more directly.
- **Source freshness configuration** — explicitly noted as out of scope (single annual data drop).

---

## 6. AI tool use

I used Claude Code as the primary coding assistant throughout this task.

### Where it helped

- **Scaffolding boilerplate** — `dbt_project.yml`, `profiles.yml`, schema.yml structure. Claude generated correct YAML with the `arguments:` keyword required by dbt 1.10+ generic tests, which I would have missed.
- **DuckDB-specific syntax** — UNPIVOT options, `quantile_cont`, `FILTER (WHERE …)` aggregate clauses, `LPAD` for the join key.
- **XLSX inspection without openpyxl installed** — Claude wrote a stdlib-only zipfile + ElementTree script that read the sheet structure directly from the XLSX archive when pandas couldn't.
- **Doc phrasing** — the recommendation table, the four-tier suppression flag definition, this paragraph.

### One decision I made differently than the AI suggested

**Aggregation: enrollment-weighted average, not simple average.** Claude's first cut at the mart used `AVG(pct_proficient)` across grades for each school × subject. That treats a 12-student grade 3 with the same weight as a 100-student grade 8 — the school's overall rate would not actually reflect its students. Overrode to:

```sql
SUM(pct_proficient * enrollment) / NULLIF(SUM(enrollment), 0)
```

with October enrollment as the per-grade weight. This is the rebuild-the-implicit-counts approach: a simple average of percentages is rarely the right way to combine ratios with different denominators.

### One output I verified and corrected

**`% proficient = Advanced + Proficient`, NOT `IndicatorValue`.** Claude initially mapped `% proficient` to the `IndicatorValue` column, presumably because the column name sounded right. I checked it against actual rows: `IndicatorValue` is in the 0–100 range but doesn't equal `Advanced + Proficient`. Cross-checked with Oklahoma OSDE documentation: `IndicatorValue` is the state's custom A–F school-grading score (a weighted composite of proficiency, growth, and other factors), not a proficiency rate. The standard "% proficient or above" metric is `Advanced + Proficient` — both of those columns are present in the file and sum to a clean percentage. Corrected the mart definition before the suppression analysis would have been computed from the wrong column.
