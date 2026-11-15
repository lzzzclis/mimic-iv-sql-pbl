-- PostgreSQL / pgAdmin. Read-only; no patient-level output.
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '60s';
SELECT current_database() AS database_name,
       current_setting('server_version') AS postgresql_version;
WITH required(schema_name, relation_name) AS (
    VALUES ('mimiciv_hosp','patients'), ('mimiciv_hosp','admissions'),
           ('mimiciv_hosp','diagnoses_icd'), ('mimiciv_hosp','d_labitems'),
           ('mimiciv_icu','icustays'), ('mimiciv_icu','d_items'),
           ('mimiciv_icu','chartevents'), ('mimiciv_derived','icustay_detail'),
           ('mimiciv_derived','oxygen_delivery'),
           ('mimiciv_derived','ventilator_setting'),
           ('mimiciv_derived','bg'), ('mimiciv_derived','ventilation')
)
SELECT schema_name, relation_name,
       to_regclass(format('%I.%I', schema_name, relation_name)) IS NOT NULL AS exists
FROM required ORDER BY schema_name, relation_name;
SELECT table_schema, table_name, column_name, data_type
FROM information_schema.columns
WHERE (table_schema = 'mimiciv_derived' AND table_name IN
       ('oxygen_delivery','ventilator_setting','bg','ventilation','icustay_detail'))
ORDER BY table_schema, table_name, ordinal_position;
COMMIT;
