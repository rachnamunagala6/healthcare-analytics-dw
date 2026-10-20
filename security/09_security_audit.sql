/* =====================================================================
   09_security_audit.sql
   Phase 5b: Audit logging and role-based access control.

   1. Audit trail: a trigger records every INSERT, UPDATE and DELETE on
      core.patients and core.encounters into audit.change_log, with who
      made the change, when, the old and new values (JSONB) and exactly
      which columns changed. (HIPAA requires tracking access to and
      changes of patient records.)
   2. Roles (least privilege):
      - hc_etl     : builds the warehouse; full access to every schema
      - hc_analyst : reads the analytics layer only. Cannot see raw
                     staging/core data, patient IDs or birth dates.
                     Gets a de-identified patient view instead.
   3. Self-test: switches into the analyst role and proves which queries
      are allowed and which are blocked.

   Run LAST, after 01-08. Rerun it whenever 02 or 04 rebuild tables,
   because dropping a table also drops its triggers and permissions.
   ===================================================================== */

CREATE SCHEMA IF NOT EXISTS audit;

-- =====================================================================
-- 1. Audit trail
-- =====================================================================
CREATE TABLE IF NOT EXISTS audit.change_log (
    change_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name      TEXT        NOT NULL,
    operation       TEXT        NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    record_id       TEXT        NOT NULL,
    changed_by      TEXT        NOT NULL DEFAULT current_user,
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    changed_columns TEXT[],                 -- UPDATE only: which columns changed
    old_data        JSONB,                  -- row before the change
    new_data        JSONB                   -- row after the change
);

-- One generic trigger function for any table. The primary key column
-- name is passed in as a trigger argument (TG_ARGV[0]).
CREATE OR REPLACE FUNCTION audit.log_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER                -- writes the log even if the user cannot
SET search_path = pg_catalog, audit
AS $$
DECLARE
    v_old JSONB;
    v_new JSONB;
    v_changed TEXT[];
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN v_old := to_jsonb(OLD); END IF;
    IF TG_OP IN ('UPDATE', 'INSERT') THEN v_new := to_jsonb(NEW); END IF;

    IF TG_OP = 'UPDATE' THEN
        SELECT array_agg(n.key ORDER BY n.key)
        INTO v_changed
        FROM jsonb_each(v_new) AS n
        WHERE n.value IS DISTINCT FROM v_old -> n.key;

        IF v_changed IS NULL THEN          -- nothing actually changed
            RETURN NEW;
        END IF;
    END IF;

    INSERT INTO audit.change_log
        (table_name, operation, record_id, changed_columns, old_data, new_data)
    VALUES
        (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
         TG_OP,
         COALESCE(v_new, v_old) ->> TG_ARGV[0],
         v_changed,
         v_old,
         v_new);

    RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_patients   ON core.patients;
DROP TRIGGER IF EXISTS trg_audit_encounters ON core.encounters;

CREATE TRIGGER trg_audit_patients
AFTER INSERT OR UPDATE OR DELETE ON core.patients
FOR EACH ROW EXECUTE FUNCTION audit.log_change('patient_id');

CREATE TRIGGER trg_audit_encounters
AFTER INSERT OR UPDATE OR DELETE ON core.encounters
FOR EACH ROW EXECUTE FUNCTION audit.log_change('encounter_id');


-- =====================================================================
-- 2. Roles
-- Roles belong to the whole server, and PostgreSQL has no
-- CREATE ROLE IF NOT EXISTS, so check the catalog first.
-- Both are group roles (NOLOGIN): real users would be made members.
-- =====================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hc_etl') THEN
        CREATE ROLE hc_etl NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hc_analyst') THEN
        CREATE ROLE hc_analyst NOLOGIN;
    END IF;
END;
$$;

-- Start from zero so the script is re-runnable
REVOKE ALL ON ALL TABLES IN SCHEMA staging, core, data_quality, analytics, audit
    FROM hc_analyst, hc_etl;
REVOKE ALL ON SCHEMA staging, core, data_quality, analytics, audit
    FROM hc_analyst, hc_etl;

-- ETL role: full access to the pipeline schemas, read-only on the audit log
GRANT USAGE, CREATE ON SCHEMA staging, core, data_quality, analytics TO hc_etl;
GRANT ALL ON ALL TABLES    IN SCHEMA staging, core, data_quality, analytics TO hc_etl;
GRANT ALL ON ALL SEQUENCES IN SCHEMA staging, core, data_quality, analytics TO hc_etl;
GRANT USAGE  ON SCHEMA audit TO hc_etl;
GRANT SELECT ON audit.change_log TO hc_etl;

-- De-identified patient view for analysts: no patient ID, no exact
-- birth or death date, no city. Birth year is kept for age analysis.
CREATE OR REPLACE VIEW analytics.v_patient_deidentified AS
SELECT patient_key,
       gender,
       race,
       ethnicity,
       EXTRACT(YEAR FROM birth_date)::int AS birth_year,
       death_date IS NOT NULL             AS is_deceased,
       county,
       payer_key,
       effective_from,
       effective_to,
       is_current
FROM analytics.dim_patient;

-- Analyst role: read the analytics layer ...
GRANT USAGE  ON SCHEMA analytics TO hc_analyst;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO hc_analyst;

-- ... except objects that expose identifiers
REVOKE SELECT ON analytics.dim_patient       FROM hc_analyst;
REVOKE SELECT ON analytics.v_patient_current FROM hc_analyst;

-- Column-level privileges: analysts may join through dim_patient,
-- but only on non-identifying columns
GRANT SELECT (patient_key, gender, race, ethnicity, county, payer_key,
              effective_from, effective_to, is_current)
    ON analytics.dim_patient TO hc_analyst;

-- Future tables created in analytics are readable by analysts automatically
ALTER DEFAULT PRIVILEGES IN SCHEMA analytics GRANT SELECT ON TABLES TO hc_analyst;


-- =====================================================================
-- 3. Self-test
-- =====================================================================

-- 3a. Audit trail: change a patient's city, then change it back.
-- Both changes are logged; the data ends up exactly as it was.
DO $$
DECLARE
    v_id   TEXT;
    v_city TEXT;
BEGIN
    SELECT patient_id, city INTO v_id, v_city
    FROM core.patients ORDER BY patient_id LIMIT 1;

    UPDATE core.patients SET city = 'AUDIT TEST' WHERE patient_id = v_id;
    UPDATE core.patients SET city = v_city       WHERE patient_id = v_id;
END;
$$;

SELECT change_id, changed_at, changed_by, table_name, operation,
       changed_columns,
       old_data ->> 'city' AS old_city,
       new_data ->> 'city' AS new_city
FROM audit.change_log
ORDER BY change_id DESC
LIMIT 4;


-- 3b. Permission tests: run each query as hc_analyst and record whether
-- it was allowed or blocked.
CREATE TEMP TABLE permission_tests (
    test_no  INTEGER,
    test     TEXT,
    expected TEXT,
    actual   TEXT,
    result   TEXT
);

DO $$
DECLARE
    t RECORD;
    v_actual TEXT;
BEGIN
    FOR t IN
        SELECT * FROM (VALUES
            (1, 'Read visit facts',                    'SELECT COUNT(*) FROM analytics.fact_encounters',          'ALLOWED'),
            (2, 'Read de-identified patients',         'SELECT COUNT(*) FROM analytics.v_patient_deidentified',   'ALLOWED'),
            (3, 'Read dashboard KPIs',                 'SELECT COUNT(*) FROM analytics.mv_monthly_kpis',          'ALLOWED'),
            (4, 'Read gender from dim_patient',        'SELECT gender FROM analytics.dim_patient LIMIT 1',        'ALLOWED'),
            (5, 'Read patient_id from dim_patient',    'SELECT patient_id FROM analytics.dim_patient LIMIT 1',    'BLOCKED'),
            (6, 'Read birth_date from dim_patient',    'SELECT birth_date FROM analytics.dim_patient LIMIT 1',    'BLOCKED'),
            (7, 'Read raw core.patients',              'SELECT COUNT(*) FROM core.patients',                      'BLOCKED'),
            (8, 'Read raw staging (contains SSNs)',    'SELECT COUNT(*) FROM staging.patients',                   'BLOCKED'),
            (9, 'Read the audit log',                  'SELECT COUNT(*) FROM audit.change_log',                   'BLOCKED'),
            (10,'Change data in the warehouse',        'DELETE FROM analytics.fact_encounters WHERE FALSE',       'BLOCKED')
        ) AS v(test_no, test, sql_text, expected)
    LOOP
        BEGIN
            EXECUTE 'SET LOCAL ROLE hc_analyst';
            EXECUTE t.sql_text;
            v_actual := 'ALLOWED';
            EXECUTE 'RESET ROLE';
        EXCEPTION WHEN insufficient_privilege THEN
            v_actual := 'BLOCKED';      -- the error also undoes SET LOCAL ROLE
        END;

        INSERT INTO permission_tests
        VALUES (t.test_no, t.test, t.expected, v_actual,
                CASE WHEN v_actual = t.expected THEN 'PASS' ELSE 'FAIL' END);
    END LOOP;
END;
$$;

SELECT test_no, test, expected, actual, result
FROM permission_tests
ORDER BY test_no;
