-- Singular test: pct_proficient should be NULL exactly when suppression_flag
-- = 'No Data' (i.e., grades_with_data = 0). Catches cases where the weighted
-- average produces NULL for an unexpected reason (e.g., a Complete school
-- where every grade has null pct_proficient — would indicate upstream bugs).
-- A test that returns 0 rows passes.

select
    school_code,
    subject,
    suppression_flag,
    grades_with_data,
    pct_proficient
from {{ ref('school_subject_proficiency') }}
where
    (suppression_flag = 'No Data' and pct_proficient is not null)
    or (suppression_flag != 'No Data' and pct_proficient is null)
