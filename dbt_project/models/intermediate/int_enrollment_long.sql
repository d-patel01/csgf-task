-- Unpivot stg_enrollment from wide (one row per school, grade columns
-- alongside) to long (one row per school × grade). Filter to grades 3–8 with
-- enrollment > 0 — this output IS the "should-have-data" universe that the
-- suppression flag is anchored to. A school that doesn't serve grade 4
-- (because it's a high school) is correctly excluded here, so it can never
-- be flagged "suppressed" for a grade it never had students in.
--
-- Implementation note: long-form via UNION ALL (one SELECT per grade column).
-- DuckDB's UNPIVOT has a view-serialization bug for the INTO NAME / VALUE
-- form (column names get materialized as string literals), so we explicitly
-- enumerate. The wrapping CTE makes stg_enrollment resolved once per query.

with stg as (
    select * from {{ ref('stg_enrollment') }}
)
select school_code, '03' as grade, grade_03 as enrollment from stg where grade_03 > 0
union all
select school_code, '04' as grade, grade_04 as enrollment from stg where grade_04 > 0
union all
select school_code, '05' as grade, grade_05 as enrollment from stg where grade_05 > 0
union all
select school_code, '06' as grade, grade_06 as enrollment from stg where grade_06 > 0
union all
select school_code, '07' as grade, grade_07 as enrollment from stg where grade_07 > 0
union all
select school_code, '08' as grade, grade_08 as enrollment from stg where grade_08 > 0
