-- 1:1 with raw_enrollment: rename to snake_case, build the compound join key,
-- expose only the columns used downstream. Stays wide; the unpivot to long
-- format happens in intermediate (it changes row count, so it's not "cleanup").
--
-- Join-key construction: the file's natural primary key is (District Code,
-- School Code). School Code alone is NOT unique across districts (e.g. school
-- code 105 appears in many districts). The compound key matches the assessment
-- file's FullCode (= CountyCode || DistrictCode || SiteCode = 9 chars).
--
-- "School Code" is read by pandas as DOUBLE because one row has it null,
-- so we cast through INTEGER to drop the trailing ".0" before string-padding.

select
    cast("District Code" as varchar)
        || lpad(cast(cast("School Code" as integer) as varchar), 3, '0') as school_code,
    "GR 03" as grade_03,
    "GR 04" as grade_04,
    "GR 05" as grade_05,
    "GR 06" as grade_06,
    "GR 07" as grade_07,
    "GR 08" as grade_08
from {{ source('oklahoma', 'raw_enrollment') }}
where "School Code" is not null
