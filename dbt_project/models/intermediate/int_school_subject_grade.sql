-- One row per (school × subject × grade) where the school has enrollment > 0
-- in that grade. LEFT JOIN to the assessment data — a missing match means
-- structural suppression (no row in the source for a grade we expected).
--
-- The is_explicitly_suppressed flag covers a defensive case: a row exists in
-- assessments but with null Advanced or Proficient (so pct_proficient can't
-- be computed). In the 2024–25 file none of our school×ELA/Math×grade-3-8×All
-- rows are like this, but we keep the check to defend against future drift.
-- We deliberately do NOT check IndicatorValue here — it's the OK A–F school
-- grade indicator, not a proficiency component, so its nullness wouldn't
-- invalidate pct_proficient.

with relevant_assessments as (
    -- inlined "int_assessments_relevant" CTE: filters, subject mapping,
    -- and metric derivation that turn raw assessment rows into the shape
    -- we'll join to the universe.
    select
        school_code,
        school_name,
        district_name,
        case subject_raw
            when 'ELA'         then 'ELA'
            when 'Mathematics' then 'Math'
        end                                       as subject,
        grade,
        pct_advanced + pct_proficient_only        as pct_proficient,
        (pct_advanced       is null
         or pct_proficient_only is null)          as is_explicitly_suppressed
    from {{ ref('stg_assessments') }}
    where agency_type = 'School'
      and subject_raw in ('ELA', 'Mathematics')
      and grade       in ('03', '04', '05', '06', '07', '08')
      and subgroup    = 'All'
),

universe as (
    -- Cross-join enrollment universe with the two subjects in scope so we
    -- have one row per (school × subject × grade) we EXPECT to see.
    select
        e.school_code,
        e.grade,
        e.enrollment,
        s.subject
    from {{ ref('int_enrollment_long') }} e
    cross join (values ('ELA'), ('Math')) as s(subject)
)

select
    u.school_code,
    u.subject,
    u.grade,
    u.enrollment,
    a.school_name,
    a.district_name,
    a.pct_proficient,
    coalesce(a.is_explicitly_suppressed, false)             as is_explicitly_suppressed,
    (a.school_code is null)                                 as is_structurally_suppressed,
    (coalesce(a.is_explicitly_suppressed, false)
     or a.school_code is null)                              as is_suppressed
from universe u
left join relevant_assessments a
    on a.school_code = u.school_code
    and a.subject    = u.subject
    and a.grade      = u.grade
