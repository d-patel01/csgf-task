-- 1:1 with raw_assessments: rename to snake_case, surface raw values.
-- No filters, no joins, no derived metrics. Filtering and metric derivation
-- happen in intermediate.

select
    FullCode             as school_code,
    SchoolName           as school_name,
    DistrictName         as district_name,
    EducationAgencyType  as agency_type,
    IndicatorSubtype     as subject_raw,
    GradeLevel           as grade,
    ReportSubgroup       as subgroup,
    Advanced             as pct_advanced,
    Proficient           as pct_proficient_only,
    IndicatorValue       as indicator_value_raw
from {{ source('oklahoma', 'raw_assessments') }}
