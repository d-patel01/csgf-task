"""Suppression analysis + performance summary on the school_subject_proficiency mart.

Computes the numbers cited in analysis.md:
  - Suppression flag distribution by subject
  - Enrollment-weighted coverage (% of students in non-suppressed schools)
  - State-level proficiency two ways (all schools vs. Complete-only) — supports
    the "depends on the question" recommendation with evidence
  - Distribution stats (median, P25, P75, etc.) for the non-technical summary
  - Small-school vs large-school suppression breakdown

Run from the project root:
    .venv/Scripts/python analysis/suppression_analysis.py
"""
from pathlib import Path
import duckdb

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / "duckdb" / "csgf.duckdb"

con = duckdb.connect(str(DB_PATH), read_only=True)


def banner(title: str) -> None:
    print()
    print("=" * 72)
    print(title)
    print("=" * 72)


# ---------------------------------------------------------------------------
# 1. Suppression flag distribution
# ---------------------------------------------------------------------------
banner("1. Suppression flag distribution by subject")
print(con.execute("""
    select
        suppression_flag,
        subject,
        count(*) as n_schools,
        round(100.0 * count(*) / sum(count(*)) over (partition by subject), 1) as pct_of_subject
    from school_subject_proficiency
    group by suppression_flag, subject
    order by subject, suppression_flag
""").fetchdf().to_string(index=False))

banner("2. Suppression flag totals (both subjects combined)")
print(con.execute("""
    select
        suppression_flag,
        count(*) as n_rows,
        round(100.0 * count(*) / sum(count(*)) over (), 1) as pct_of_total
    from school_subject_proficiency
    group by suppression_flag
    order by
        case suppression_flag
            when 'Complete' then 1
            when 'Partial' then 2
            when 'Severely Suppressed' then 3
            when 'No Data' then 4
        end
""").fetchdf().to_string(index=False))


# ---------------------------------------------------------------------------
# 2. Enrollment coverage — what fraction of students live in Complete schools?
# ---------------------------------------------------------------------------
banner("3. Enrollment coverage by suppression tier")
print(con.execute("""
    select
        suppression_flag,
        subject,
        count(*) as n_schools,
        sum(enrollment_in_universe) as total_enrollment,
        round(100.0 * sum(enrollment_in_universe)
              / sum(sum(enrollment_in_universe)) over (partition by subject), 1)
            as pct_of_state_enrollment
    from school_subject_proficiency
    group by suppression_flag, subject
    order by subject, suppression_flag
""").fetchdf().to_string(index=False))


# ---------------------------------------------------------------------------
# 3. State-level proficiency two ways — supports the recommendation
# ---------------------------------------------------------------------------
banner("4. State-level pct_proficient: all schools vs. Complete-only")
print(con.execute("""
    with all_schools as (
        select
            subject,
            sum(pct_proficient * enrollment_with_data)
                / nullif(sum(enrollment_with_data), 0) as pct_prof_all
        from school_subject_proficiency
        where pct_proficient is not null
        group by subject
    ),
    complete_only as (
        select
            subject,
            sum(pct_proficient * enrollment_with_data)
                / nullif(sum(enrollment_with_data), 0) as pct_prof_complete
        from school_subject_proficiency
        where suppression_flag = 'Complete'
        group by subject
    )
    select
        a.subject,
        round(a.pct_prof_all, 2) as state_avg_all_schools,
        round(c.pct_prof_complete, 2) as state_avg_complete_only,
        round(c.pct_prof_complete - a.pct_prof_all, 2) as delta_pp
    from all_schools a
    join complete_only c using (subject)
    order by a.subject
""").fetchdf().to_string(index=False))


# ---------------------------------------------------------------------------
# 4. Distribution stats for the non-technical summary
# ---------------------------------------------------------------------------
banner("5. Distribution of pct_proficient (Complete + Partial schools only)")
print(con.execute("""
    select
        subject,
        count(*) as n_schools,
        round(min(pct_proficient), 1) as min_pp,
        round(quantile_cont(pct_proficient, 0.10), 1) as p10,
        round(quantile_cont(pct_proficient, 0.25), 1) as p25,
        round(quantile_cont(pct_proficient, 0.50), 1) as median,
        round(quantile_cont(pct_proficient, 0.75), 1) as p75,
        round(quantile_cont(pct_proficient, 0.90), 1) as p90,
        round(max(pct_proficient), 1) as max_pp,
        round(avg(pct_proficient), 1) as mean_pp
    from school_subject_proficiency
    where pct_proficient is not null
    group by subject
    order by subject
""").fetchdf().to_string(index=False))


# ---------------------------------------------------------------------------
# 5. Small school vs large school suppression — concentration by size
# ---------------------------------------------------------------------------
banner("6. Suppression by school size bucket")
print(con.execute("""
    with sized as (
        select *,
            case
                when enrollment_in_universe < 50  then '1) <50 students'
                when enrollment_in_universe < 150 then '2) 50–149'
                when enrollment_in_universe < 300 then '3) 150–299'
                when enrollment_in_universe < 600 then '4) 300–599'
                else                                   '5) 600+'
            end as size_bucket
        from school_subject_proficiency
        where subject = 'ELA'  -- one subject for clarity, results similar for Math
    )
    select
        size_bucket,
        count(*) as n_schools,
        sum(case when suppression_flag = 'Complete'            then 1 else 0 end) as complete,
        sum(case when suppression_flag = 'Partial'             then 1 else 0 end) as partial,
        sum(case when suppression_flag = 'Severely Suppressed' then 1 else 0 end) as severely,
        sum(case when suppression_flag = 'No Data'             then 1 else 0 end) as no_data,
        round(100.0 * sum(case when suppression_flag != 'Complete' then 1 else 0 end)
              / count(*), 1) as pct_not_complete
    from sized
    group by size_bucket
    order by size_bucket
""").fetchdf().to_string(index=False))


# ---------------------------------------------------------------------------
# 6. Median proficiency: Complete vs. Partial schools (selection bias check)
# ---------------------------------------------------------------------------
banner("7. Median pct_proficient: Complete vs. Partial schools")
print(con.execute("""
    select
        subject,
        suppression_flag,
        count(*) as n,
        round(quantile_cont(pct_proficient, 0.50), 1) as median_pp,
        round(avg(pct_proficient), 1) as mean_pp
    from school_subject_proficiency
    where suppression_flag in ('Complete', 'Partial')
    group by subject, suppression_flag
    order by subject, suppression_flag
""").fetchdf().to_string(index=False))


# ---------------------------------------------------------------------------
# 7. Top, middle, bottom example schools for the non-technical narrative
# ---------------------------------------------------------------------------
banner("8. Example schools at top / median / bottom (Complete + size > 100)")

# Pull the actual ELA median dynamically so the "middle" example is at the
# real center of the distribution, not a hard-coded round number.
ela_median = con.execute("""
    select quantile_cont(pct_proficient, 0.50)
    from school_subject_proficiency
    where subject = 'ELA' and pct_proficient is not null
""").fetchone()[0]
print(f"(ELA median = {ela_median:.1f}%)")

for label, order_clause in [
    ("TOP",    "pct_proficient desc"),
    ("MEDIAN", f"abs(pct_proficient - {ela_median}) asc"),
    ("BOTTOM", "pct_proficient asc"),
]:
    print(f"\n--- {label} 3 (ELA) ---")
    print(con.execute(f"""
        select school_name, district_name,
               round(pct_proficient, 1) as pct_prof,
               cast(enrollment_in_universe as integer) as enrollment
        from school_subject_proficiency
        where subject = 'ELA'
          and suppression_flag = 'Complete'
          and enrollment_in_universe > 100
        order by {order_clause}
        limit 3
    """).fetchdf().to_string(index=False))


con.close()
