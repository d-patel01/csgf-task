-- Comprehensive sanity check of the pipeline, run via the DuckDB CLI.
-- Run with:
--   .venv/Scripts/duckdb -readonly duckdb/csgf.duckdb -c ".read scripts/verify.sql"

.mode markdown
.maxrows 100

.print
.print ============================================================
.print A. LAYER RECONCILIATION (row counts at every layer)
.print ============================================================
SELECT 'raw_assessments'              AS layer, COUNT(*) AS n FROM raw_assessments
UNION ALL SELECT 'raw_enrollment',                        COUNT(*) FROM raw_enrollment
UNION ALL SELECT 'stg_assessments',                       COUNT(*) FROM stg_assessments
UNION ALL SELECT 'stg_enrollment',                        COUNT(*) FROM stg_enrollment
UNION ALL SELECT 'int_enrollment_long',                   COUNT(*) FROM int_enrollment_long
UNION ALL SELECT 'int_school_subject_grade',              COUNT(*) FROM int_school_subject_grade
UNION ALL SELECT 'school_subject_proficiency',            COUNT(*) FROM school_subject_proficiency;

.print
.print --- A.1 staging is 1:1 with raw (assessments) ---
SELECT (SELECT COUNT(*) FROM raw_assessments) = (SELECT COUNT(*) FROM stg_assessments) AS staging_assessments_is_1_to_1;

.print
.print --- A.2 stg_enrollment drops null School Code rows (1,780 raw - 1 null = 1,779) ---
SELECT
    (SELECT COUNT(*) FROM raw_enrollment) AS raw_n,
    (SELECT COUNT(*) FROM raw_enrollment WHERE "School Code" IS NULL) AS raw_null_school_code,
    (SELECT COUNT(*) FROM stg_enrollment) AS stg_n;


.print
.print ============================================================
.print B. JOIN-KEY CORRECTNESS
.print ============================================================
.print --- B.1 All compound school_codes are exactly 9 chars on both sides ---
SELECT 'enrollment' AS side, MIN(LENGTH(school_code)) AS min_len, MAX(LENGTH(school_code)) AS max_len, COUNT(DISTINCT LENGTH(school_code)) AS n_distinct_lens
FROM stg_enrollment
UNION ALL
SELECT 'assessments (school-level only)', MIN(LENGTH(school_code)), MAX(LENGTH(school_code)), COUNT(DISTINCT LENGTH(school_code))
FROM stg_assessments
WHERE agency_type = 'School';

.print
.print --- B.2 Match-rate from enrollment side ---
SELECT
    COUNT(DISTINCT e.school_code)                                                 AS enrollment_schools,
    COUNT(DISTINCT CASE WHEN a.school_code IS NOT NULL THEN e.school_code END)    AS matched,
    ROUND(100.0 * COUNT(DISTINCT CASE WHEN a.school_code IS NOT NULL THEN e.school_code END)
          / COUNT(DISTINCT e.school_code), 1)                                     AS match_pct
FROM stg_enrollment e
LEFT JOIN stg_assessments a
  ON a.school_code = e.school_code AND a.agency_type = 'School';

.print
.print --- B.3 Sample of UNMATCHED enrollment schools (expect HS / alt schools / no-elementary-grade-3-8 schools) ---
SELECT e.school_code,
       (SELECT COUNT(*) FROM int_enrollment_long il WHERE il.school_code = e.school_code) AS grades_3_to_8_in_universe
FROM stg_enrollment e
LEFT JOIN stg_assessments a
  ON a.school_code = e.school_code AND a.agency_type = 'School'
WHERE a.school_code IS NULL
LIMIT 5;


.print
.print ============================================================
.print C. UNIVERSE CORRECTNESS (int_enrollment_long defines who must report)
.print ============================================================
.print --- C.1 every row in int_enrollment_long has enrollment > 0 ---
SELECT
    COUNT(*) AS total_rows,
    COUNT(*) FILTER (WHERE enrollment > 0) AS positive_enrollment,
    COUNT(*) FILTER (WHERE enrollment <= 0 OR enrollment IS NULL) AS bad_rows
FROM int_enrollment_long;

.print
.print --- C.2 int_school_subject_grade rows = int_enrollment_long rows x 2 subjects ---
SELECT
    (SELECT COUNT(*) FROM int_enrollment_long)        AS universe_rows,
    (SELECT COUNT(*) FROM int_school_subject_grade)   AS isg_rows,
    (SELECT COUNT(*) FROM int_school_subject_grade) = 2 * (SELECT COUNT(*) FROM int_enrollment_long) AS exactly_2x;


.print
.print ============================================================
.print D. SUPPRESSION FLAG LOGIC (each tier matches its definition)
.print ============================================================
.print --- D.1 Cross-tab: ratio of grades_with_data / grades_in_universe by flag ---
SELECT
    suppression_flag,
    MIN(grades_with_data)            AS min_with,
    MAX(grades_with_data)            AS max_with,
    MIN(grades_in_universe)          AS min_universe,
    MAX(grades_in_universe)          AS max_universe,
    MIN(ROUND(1.0 * grades_with_data / grades_in_universe, 2)) AS min_ratio,
    MAX(ROUND(1.0 * grades_with_data / grades_in_universe, 2)) AS max_ratio
FROM school_subject_proficiency
GROUP BY suppression_flag
ORDER BY suppression_flag;

.print
.print --- D.2 Spot-check Complete: should always have grades_with_data = grades_in_universe ---
SELECT COUNT(*) AS violations
FROM school_subject_proficiency
WHERE suppression_flag = 'Complete' AND grades_with_data != grades_in_universe;

.print
.print --- D.3 Spot-check No Data: should always have grades_with_data = 0 ---
SELECT COUNT(*) AS violations
FROM school_subject_proficiency
WHERE suppression_flag = 'No Data' AND grades_with_data != 0;

.print
.print --- D.4 Spot-check Severely Suppressed: ratio strictly < 0.5 ---
SELECT COUNT(*) AS violations
FROM school_subject_proficiency
WHERE suppression_flag = 'Severely Suppressed'
  AND 1.0 * grades_with_data / grades_in_universe >= 0.5;

.print
.print --- D.5 Spot-check Partial: 0.5 <= ratio < 1.0 ---
SELECT COUNT(*) AS violations
FROM school_subject_proficiency
WHERE suppression_flag = 'Partial'
  AND (1.0 * grades_with_data / grades_in_universe < 0.5
       OR grades_with_data >= grades_in_universe);


.print
.print ============================================================
.print E. AGGREGATION MATH (manually recompute pct_proficient for JENKS MS)
.print ============================================================
.print --- E.1 Per-grade detail for JENKS MS ELA ---
SELECT i.grade, i.enrollment, i.pct_proficient,
       i.pct_proficient * i.enrollment AS pct_x_enroll
FROM int_school_subject_grade i
WHERE i.school_name = 'JENKS MS' AND i.subject = 'ELA'
ORDER BY i.grade;

.print
.print --- E.2 Manually computed weighted avg vs mart's pct_proficient ---
WITH manual AS (
    SELECT SUM(pct_proficient * enrollment) / NULLIF(SUM(enrollment), 0) AS manual_avg
    FROM int_school_subject_grade
    WHERE school_name = 'JENKS MS' AND subject = 'ELA' AND NOT is_suppressed
)
SELECT
    ROUND(manual.manual_avg, 4)                          AS manual_calc,
    ROUND(mart.pct_proficient, 4)                        AS mart_value,
    ROUND(manual.manual_avg - mart.pct_proficient, 6)    AS difference
FROM manual,
     (SELECT pct_proficient FROM school_subject_proficiency WHERE school_name = 'JENKS MS' AND subject = 'ELA') AS mart;


.print
.print ============================================================
.print F. NULL INVARIANTS
.print ============================================================
.print --- F.1 pct_proficient NULL iff suppression_flag = No Data ---
SELECT
    COUNT(*) FILTER (WHERE suppression_flag = 'No Data' AND pct_proficient IS NOT NULL) AS no_data_with_value,
    COUNT(*) FILTER (WHERE suppression_flag != 'No Data' AND pct_proficient IS NULL)    AS not_no_data_with_null
FROM school_subject_proficiency;

.print
.print --- F.2 pct_proficient bounded between 0 and 100 ---
SELECT
    MIN(pct_proficient) AS min_pp,
    MAX(pct_proficient) AS max_pp,
    COUNT(*) FILTER (WHERE pct_proficient < 0 OR pct_proficient > 100) AS out_of_range
FROM school_subject_proficiency;


.print
.print ============================================================
.print G. REPRODUCE NUMBERS DOCUMENTED IN analysis.md
.print ============================================================
.print --- G.1 Tier counts (analysis.md: Complete 1795, Partial 157, Severely Suppressed 96, No Data 398) ---
SELECT suppression_flag, COUNT(*) AS n
FROM school_subject_proficiency
GROUP BY 1 ORDER BY 1;

.print
.print --- G.2 State-level pct_proficient all-schools (analysis.md: ELA 25.28, Math 27.46) ---
SELECT
    subject,
    ROUND(SUM(pct_proficient * enrollment_with_data) / SUM(enrollment_with_data), 2) AS state_pct_prof
FROM school_subject_proficiency
WHERE pct_proficient IS NOT NULL
GROUP BY subject
ORDER BY subject;

.print
.print --- G.3 State-level pct_proficient Complete-only and the delta (analysis.md: ELA +0.04, Math 0.00) ---
WITH all_s AS (
    SELECT subject,
           SUM(pct_proficient * enrollment_with_data) / NULLIF(SUM(enrollment_with_data), 0) AS pp_all
    FROM school_subject_proficiency
    WHERE pct_proficient IS NOT NULL
    GROUP BY subject
),
complete_s AS (
    SELECT subject,
           SUM(pct_proficient * enrollment_with_data) / NULLIF(SUM(enrollment_with_data), 0) AS pp_complete
    FROM school_subject_proficiency
    WHERE suppression_flag = 'Complete'
    GROUP BY subject
)
SELECT
    a.subject,
    ROUND(a.pp_all, 2)                            AS all_schools,
    ROUND(c.pp_complete, 2)                       AS complete_only,
    ROUND(c.pp_complete - a.pp_all, 2)            AS delta_pp
FROM all_s a JOIN complete_s c USING (subject)
ORDER BY a.subject;

.print
.print --- G.4 Distribution percentiles (analysis.md: ELA median 23.9, Math 26.5) ---
SELECT
    subject,
    ROUND(quantile_cont(pct_proficient, 0.10), 1) AS p10,
    ROUND(quantile_cont(pct_proficient, 0.25), 1) AS p25,
    ROUND(quantile_cont(pct_proficient, 0.50), 1) AS median,
    ROUND(quantile_cont(pct_proficient, 0.75), 1) AS p75,
    ROUND(quantile_cont(pct_proficient, 0.90), 1) AS p90,
    ROUND(AVG(pct_proficient), 1)                 AS mean
FROM school_subject_proficiency
WHERE pct_proficient IS NOT NULL
GROUP BY subject ORDER BY subject;

.print
.print --- G.5 Enrollment coverage by tier (analysis.md ELA: Complete 89.9%, No Data 4.8%, Partial 3.5%, SS 1.8%) ---
SELECT
    suppression_flag,
    SUM(enrollment_in_universe) AS total_enroll,
    ROUND(100.0 * SUM(enrollment_in_universe) / SUM(SUM(enrollment_in_universe)) OVER (), 1) AS pct_of_state
FROM school_subject_proficiency
WHERE subject = 'ELA'
GROUP BY suppression_flag
ORDER BY suppression_flag;

.print
.print --- G.6 Size-bucket suppression (analysis.md: <50 -> 94.2 pct not Complete, etc.) ---
WITH sized AS (
    SELECT *,
        CASE
            WHEN enrollment_in_universe < 50  THEN '1) <50'
            WHEN enrollment_in_universe < 150 THEN '2) 50-149'
            WHEN enrollment_in_universe < 300 THEN '3) 150-299'
            WHEN enrollment_in_universe < 600 THEN '4) 300-599'
            ELSE                                   '5) 600+'
        END AS size_bucket
    FROM school_subject_proficiency
    WHERE subject = 'ELA'
)
SELECT
    size_bucket,
    COUNT(*) AS n_schools,
    ROUND(100.0 * SUM(CASE WHEN suppression_flag != 'Complete' THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_not_complete
FROM sized GROUP BY 1 ORDER BY 1;
