-- Counts of source objects, NOT a reproduction cohort.
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '60s';
SELECT 'patients' AS source, COUNT(*) AS rows,
       COUNT(DISTINCT subject_id) AS distinct_patients
FROM mimiciv_hosp.patients
UNION ALL
SELECT 'admissions', COUNT(*), COUNT(DISTINCT subject_id)
FROM mimiciv_hosp.admissions
UNION ALL
SELECT 'icustays', COUNT(*), COUNT(DISTINCT subject_id)
FROM mimiciv_icu.icustays;
SELECT COUNT(*) AS icu_stays,
       COUNT(DISTINCT stay_id) AS distinct_icu_stays,
       COUNT(DISTINCT hadm_id) AS hospital_admissions_with_icu,
       COUNT(DISTINCT subject_id) AS patients_with_icu
FROM mimiciv_icu.icustays;
COMMIT;
