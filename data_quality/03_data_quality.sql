/* =====================================================================
   03_data_quality.sql
   Phase 2: Automated data quality checks on the core schema.

   Design (metadata-driven):
   - data_quality.dq_checks       : one row per rule. Each rule is a SQL
                                     query that returns the id of every
                                     record that FAILS the rule.
   - data_quality.dq_runs         : one row each time the checks are run.
   - data_quality.dq_results      : issue count per rule, per run.
   - data_quality.dq_issue_detail : the exact failing record ids, per run,
                                     so every issue can be traced.
   - data_quality.run_dq_checks() : stored procedure that runs every active
                                     rule and logs the results.

   Adding a new rule = inserting one row into dq_checks. No code changes.

   Re-runnable. Run while connected to the healthcare_dw database.
   ===================================================================== */

-- ---------------------------------------------------------------------
-- 0. Clean rebuild
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS data_quality.run_dq_checks();
DROP TABLE IF EXISTS data_quality.dq_issue_detail CASCADE;
DROP TABLE IF EXISTS data_quality.dq_results      CASCADE;
DROP TABLE IF EXISTS data_quality.dq_runs         CASCADE;
DROP TABLE IF EXISTS data_quality.dq_checks       CASCADE;


-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------
CREATE TABLE data_quality.dq_checks (
    check_id    INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    check_name  TEXT    NOT NULL UNIQUE,
    table_name  TEXT    NOT NULL,
    category    TEXT    NOT NULL CHECK (category IN
                    ('Validity', 'Consistency', 'Uniqueness', 'Completeness', 'Plausibility')),
    severity    TEXT    NOT NULL CHECK (severity IN ('ERROR', 'WARNING')),
    description TEXT    NOT NULL,
    check_sql   TEXT    NOT NULL,   -- must return one column: the failing record id
    is_active   BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE data_quality.dq_runs (
    run_id       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
    finished_at  TIMESTAMP,
    checks_run   INTEGER,
    total_issues BIGINT
);

CREATE TABLE data_quality.dq_results (
    run_id      INTEGER NOT NULL REFERENCES data_quality.dq_runs (run_id),
    check_id    INTEGER NOT NULL REFERENCES data_quality.dq_checks (check_id),
    rows_tested BIGINT  NOT NULL,
    issue_count BIGINT  NOT NULL,
    status      TEXT    NOT NULL,
    PRIMARY KEY (run_id, check_id)
);

CREATE TABLE data_quality.dq_issue_detail (
    run_id    INTEGER NOT NULL REFERENCES data_quality.dq_runs (run_id),
    check_id  INTEGER NOT NULL REFERENCES data_quality.dq_checks (check_id),
    record_id TEXT    NOT NULL
);


-- ---------------------------------------------------------------------
-- 2. The rules
-- ---------------------------------------------------------------------
INSERT INTO data_quality.dq_checks
    (check_name, table_name, category, severity, description, check_sql)
VALUES

-- Patients ------------------------------------------------------------
('patient_death_before_birth', 'patients', 'Consistency', 'ERROR',
 'Death date is earlier than birth date',
 $q$ SELECT patient_id FROM core.patients
     WHERE death_date < birth_date $q$),

('patient_birth_in_future', 'patients', 'Validity', 'ERROR',
 'Birth date is in the future',
 $q$ SELECT patient_id FROM core.patients
     WHERE birth_date > CURRENT_DATE $q$),

('patient_no_encounters', 'patients', 'Completeness', 'WARNING',
 'Patient has no encounters on record',
 $q$ SELECT p.patient_id FROM core.patients p
     WHERE NOT EXISTS (SELECT 1 FROM core.encounters e
                       WHERE e.patient_id = p.patient_id) $q$),

-- Encounters ----------------------------------------------------------
('encounter_stop_before_start', 'encounters', 'Consistency', 'ERROR',
 'Encounter ends before it starts',
 $q$ SELECT encounter_id FROM core.encounters
     WHERE stop_ts < start_ts $q$),

('encounter_after_death', 'encounters', 'Consistency', 'ERROR',
 'Encounter starts after the patient''s death date',
 $q$ SELECT e.encounter_id
     FROM core.encounters e
     JOIN core.patients p ON p.patient_id = e.patient_id
     WHERE p.death_date IS NOT NULL
       AND e.start_ts::date > p.death_date $q$),

('encounter_coverage_exceeds_cost', 'encounters', 'Consistency', 'ERROR',
 'Payer paid more than the total claim cost',
 $q$ SELECT encounter_id FROM core.encounters
     WHERE payer_coverage > total_claim_cost $q$),

('encounter_missing_provider', 'encounters', 'Completeness', 'WARNING',
 'Encounter has no provider',
 $q$ SELECT encounter_id FROM core.encounters
     WHERE provider_id IS NULL $q$),

('encounter_missing_payer', 'encounters', 'Completeness', 'WARNING',
 'Encounter has no payer',
 $q$ SELECT encounter_id FROM core.encounters
     WHERE payer_id IS NULL $q$),

('encounter_duplicate', 'encounters', 'Uniqueness', 'WARNING',
 'Same patient, start time and encounter code appear more than once',
 $q$ SELECT encounter_id FROM (
         SELECT encounter_id,
                COUNT(*) OVER (PARTITION BY patient_id, start_ts, code) AS n
         FROM core.encounters) d
     WHERE n > 1 $q$),

('encounter_long_stay', 'encounters', 'Plausibility', 'WARNING',
 'Inpatient stay longer than 365 days',
 $q$ SELECT encounter_id FROM core.encounters
     WHERE encounter_class = 'inpatient'
       AND stop_ts - start_ts > INTERVAL '365 days' $q$),

-- Conditions ----------------------------------------------------------
('condition_stop_before_start', 'conditions', 'Consistency', 'ERROR',
 'Condition resolves before it starts',
 $q$ SELECT condition_id::text FROM core.conditions
     WHERE stop_date < start_date $q$),

('condition_duplicate', 'conditions', 'Uniqueness', 'WARNING',
 'Same patient, condition code and start date appear more than once',
 $q$ SELECT condition_id::text FROM (
         SELECT condition_id,
                COUNT(*) OVER (PARTITION BY patient_id, code, start_date) AS n
         FROM core.conditions) d
     WHERE n > 1 $q$),

-- Medications ---------------------------------------------------------
('medication_stop_before_start', 'medications', 'Consistency', 'ERROR',
 'Medication stops before it starts',
 $q$ SELECT medication_id::text FROM core.medications
     WHERE stop_ts < start_ts $q$),

-- Observations --------------------------------------------------------
('observation_numeric_unparsed', 'observations', 'Validity', 'ERROR',
 'Observation is flagged numeric but its value is not a number',
 $q$ SELECT observation_id::text FROM core.observations
     WHERE value_type = 'numeric' AND value_numeric IS NULL $q$),

('observation_systolic_bp_range', 'observations', 'Plausibility', 'WARNING',
 'Systolic blood pressure outside 50-260 mmHg (LOINC 8480-6)',
 $q$ SELECT observation_id::text FROM core.observations
     WHERE code = '8480-6'
       AND value_numeric NOT BETWEEN 50 AND 260 $q$),

('observation_heart_rate_range', 'observations', 'Plausibility', 'WARNING',
 'Heart rate outside 20-250 beats/min (LOINC 8867-4)',
 $q$ SELECT observation_id::text FROM core.observations
     WHERE code = '8867-4'
       AND value_numeric NOT BETWEEN 20 AND 250 $q$),

('observation_bmi_range', 'observations', 'Plausibility', 'WARNING',
 'BMI outside 10-80 kg/m2 (LOINC 39156-5)',
 $q$ SELECT observation_id::text FROM core.observations
     WHERE code = '39156-5'
       AND value_numeric NOT BETWEEN 10 AND 80 $q$),

('observation_after_death', 'observations', 'Consistency', 'ERROR',
 'Observation recorded after the patient''s death date',
 $q$ SELECT o.observation_id::text
     FROM core.observations o
     JOIN core.patients p ON p.patient_id = o.patient_id
     WHERE p.death_date IS NOT NULL
       AND o.observed_ts::date > p.death_date $q$);


-- ---------------------------------------------------------------------
-- 3. Stored procedure: run every active rule and log the results
-- ---------------------------------------------------------------------
CREATE PROCEDURE data_quality.run_dq_checks()
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id  INTEGER;
    v_check   RECORD;
    v_tested  BIGINT;
    v_issues  BIGINT;
    v_checks  INTEGER := 0;
    v_total   BIGINT  := 0;
BEGIN
    INSERT INTO data_quality.dq_runs DEFAULT VALUES
    RETURNING run_id INTO v_run_id;

    FOR v_check IN
        SELECT * FROM data_quality.dq_checks
        WHERE is_active
        ORDER BY check_id
    LOOP
        -- Log every failing record
        EXECUTE format(
            'INSERT INTO data_quality.dq_issue_detail (run_id, check_id, record_id)
             SELECT %s, %s, failing.id::text FROM (%s) AS failing(id)',
            v_run_id, v_check.check_id, v_check.check_sql);
        GET DIAGNOSTICS v_issues = ROW_COUNT;

        -- How many rows the rule looked at
        EXECUTE format('SELECT COUNT(*) FROM core.%I', v_check.table_name)
        INTO v_tested;

        INSERT INTO data_quality.dq_results
            (run_id, check_id, rows_tested, issue_count, status)
        VALUES
            (v_run_id, v_check.check_id, v_tested, v_issues,
             CASE WHEN v_issues = 0 THEN 'PASS' ELSE v_check.severity END);

        v_checks := v_checks + 1;
        v_total  := v_total + v_issues;
    END LOOP;

    UPDATE data_quality.dq_runs
    SET finished_at  = clock_timestamp(),
        checks_run   = v_checks,
        total_issues = v_total
    WHERE run_id = v_run_id;

    RAISE NOTICE 'Data quality run % complete: % checks, % issues found',
                 v_run_id, v_checks, v_total;
END;
$$;


-- ---------------------------------------------------------------------
-- 4. Run the checks
-- ---------------------------------------------------------------------
CALL data_quality.run_dq_checks();


-- ---------------------------------------------------------------------
-- 5. Report for the latest run
-- ---------------------------------------------------------------------
SELECT c.table_name,
       c.check_name,
       c.category,
       r.status,
       r.issue_count,
       r.rows_tested,
       ROUND(100.0 * r.issue_count / NULLIF(r.rows_tested, 0), 2) AS pct_affected,
       c.description
FROM data_quality.dq_results r
JOIN data_quality.dq_checks  c ON c.check_id = r.check_id
WHERE r.run_id = (SELECT MAX(run_id) FROM data_quality.dq_runs)
ORDER BY (r.status = 'PASS'), r.issue_count DESC, c.table_name, c.check_name;
