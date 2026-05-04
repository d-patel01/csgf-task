-- Final mart: one row per (school × subject) with enrollment-weighted
-- pct_proficient across grades 3–8 and a 4-tier suppression flag.
--
-- Aggregation methodology: weighted average using October 2024 enrollment
-- as the per-grade weight (proxy for tested-n). A simple per-grade average
-- would weight a 12-student grade equally with a 100-student grade — wrong
-- for "the school's overall rate."
--
-- Suppression flag tiers (universe = grades 3–8 with enrollment > 0):
--   Complete             — every served grade has data
--   Partial              — at least one grade missing, coverage ≥ 50%
--   Severely Suppressed  — coverage < 50%
--   No Data              — zero grades have data

with agg as (
    select
        school_code,
        subject,
        any_value(school_name)   as school_name,
        any_value(district_name) as district_name,
        count(*) filter (where not is_suppressed)         as grades_with_data,
        count(*)                                          as grades_in_universe,
        sum(pct_proficient * enrollment) filter (where not is_suppressed)
            / nullif(sum(enrollment) filter (where not is_suppressed), 0)
                                                          as pct_proficient,
        sum(enrollment) filter (where not is_suppressed)  as enrollment_with_data,
        sum(enrollment)                                   as enrollment_in_universe
    from {{ ref('int_school_subject_grade') }}
    group by school_code, subject
)
select
    *,
    case
        when grades_with_data = 0                          then 'No Data'
        when grades_with_data < 0.5 * grades_in_universe   then 'Severely Suppressed'
        when grades_with_data < grades_in_universe         then 'Partial'
        else 'Complete'
    end as suppression_flag
from agg
