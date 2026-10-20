/* =====================================================================
   08_performance.sql
   Phase 5: Performance tuning, measured before and after.

   What this script does
   1. Builds a small benchmarking framework (perf schema): a list of
      representative queries and a procedure that times each one.
   2. Times every query with NO extra indexes  -> "before"
   3. Adds targeted indexes:
        - composite indexes for the most common lookups
        - a covering index (INCLUDE) so A1C history needs no table reads
        - a partial index for inpatient stays only
        - indexes on foreign keys (PostgreSQL does not create these itself)
   4. Times every query again                 -> "after"
   5. Partitions the observations table by year and shows partition pruning
   6. Builds a materialized view for dashboard KPIs, with a refresh procedure
   7. Prints a before/after comparison report

   Run after 01-07. Re-runnable: indexes are dropped first so "before" is
   always measured fairly. Takes a few minutes on a large dataset.
   ===================================================================== */

CREATE SCHEMA IF NOT EXISTS perf;

-- ---------------------------------------------------------------------
-- 0. Reset: remove objects this script creates
-- ---------------------------------------------------------------------
DROP INDEX IF EXISTS core.ix_encounters_patient_start;
DROP INDEX IF EXISTS core.ix_observations_code_patient_ts;
DROP INDEX IF EXISTS core.ix_conditions_patient;
DROP INDEX IF EXISTS core.ix_medications_patient;
DROP INDEX IF EXISTS core.ix_immunizations_patient_ts;
DROP INDEX IF EXISTS analytics.ix_fact_enc_inpatient;
DROP INDEX IF EXISTS analytics.ix_fact_enc_start_date;
DROP INDEX IF EXISTS analytics.ix_fact_enc_patient;
DROP INDEX IF EXISTS analytics.ix_fact_diag_patient;
DROP INDEX IF EXISTS analytics.ix_dim_patient_lookup;
DROP MATERIALIZED VIEW IF EXISTS analytics.mv_monthly_kpis;
DROP PROCEDURE IF EXISTS analytics.refresh_dashboard_kpis();
DROP TABLE IF EXISTS core.observations_by_year CASCADE;
DROP PROCEDURE IF EXISTS perf.run_benchmarks(TEXT, INTEGER);
DROP FUNCTION  IF EXISTS perf.time_query(TEXT, INTEGER);
DROP TABLE IF EXISTS perf.benchmark_results;
DROP TABLE IF EXISTS perf.benchmark_queries;

ANALYZE;   -- fresh planner statistics before measuring


-- =====================================================================
-- 1. Benchmark framework
-- =====================================================================
CREATE TABLE perf.benchmark_queries (
    query_name  TEXT PRIMARY KEY,
    purpose     TEXT NOT NULL,
    query_sql   TEXT NOT NULL
);

CREATE TABLE perf.benchmark_results (
    query_name  TEXT      NOT NULL,
    run_label   TEXT      NOT NULL,        -- 'before' or 'after'
    runs        INTEGER   NOT NULL,
    avg_ms      NUMERIC   NOT NULL,
    measured_at TIMESTAMP NOT NULL DEFAULT now(),
    PRIMARY KEY (query_name, run_label)
);

-- Runs a query once to warm the cache, then p_runs more times, and
-- returns the average time in milliseconds.
CREATE FUNCTION perf.time_query(p_sql TEXT, p_runs INTEGER DEFAULT 5)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_start TIMESTAMP;
    v_total NUMERIC := 0;
    v_rows  BIGINT;
BEGIN
    -- "WHERE q IS NOT NULL" references every column, which stops the planner
    -- from skipping work whose result would otherwise be thrown away
    EXECUTE format('SELECT COUNT(*) FROM (%s) q WHERE q IS NOT NULL', p_sql) INTO v_rows;  -- warm-up
    FOR i IN 1..p_runs LOOP
        v_start := clock_timestamp();
        EXECUTE format('SELECT COUNT(*) FROM (%s) q WHERE q IS NOT NULL', p_sql) INTO v_rows;
        v_total := v_total + EXTRACT(EPOCH FROM clock_timestamp() - v_start) * 1000;
    END LOOP;
    RETURN ROUND(v_total / p_runs, 2);
END;
$$;

CREATE PROCEDURE perf.run_benchmarks(p_label TEXT, p_runs INTEGER DEFAULT 5)
LANGUAGE plpgsql
AS $$
DECLARE
    q RECORD;
BEGIN
    FOR q IN SELECT * FROM perf.benchmark_queries ORDER BY query_name LOOP
        INSERT INTO perf.benchmark_results (query_name, run_label, runs, avg_ms)
        VALUES (q.query_name, p_label, p_runs, perf.time_query(q.query_sql, p_runs))
        ON CONFLICT (query_name, run_label)
        DO UPDATE SET avg_ms = EXCLUDED.avg_ms, runs = EXCLUDED.runs,
                      measured_at = now();
    END LOOP;
END;
$$;

-- The workload: realistic queries an app or analyst runs all the time.
INSERT INTO perf.benchmark_queries (query_name, purpose, query_sql) VALUES
('patient_timeline',
 'All visits for one patient, newest first (a patient chart screen)',
 $q$ SELECT e.* FROM core.encounters e
     WHERE e.patient_id IN (SELECT patient_id FROM core.patients
                            ORDER BY patient_id LIMIT 25)
     ORDER BY e.patient_id, e.start_ts DESC $q$),

('a1c_history_all_patients',
 'Every A1C lab result in time order per patient (diabetes analysis)',
 $q$ SELECT patient_id, observed_ts, value_numeric
     FROM core.observations
     WHERE code = '4548-4'
     ORDER BY patient_id, observed_ts $q$),

('patient_diagnoses',
 'Diagnosis and medication lists for a set of patients',
 $q$ SELECT c.patient_id, c.description, m.description AS medication
     FROM core.conditions c
     LEFT JOIN core.medications m ON m.patient_id = c.patient_id
                                 AND m.reason_code = c.code
     WHERE c.patient_id IN (SELECT patient_id FROM core.patients
                            ORDER BY patient_id LIMIT 25) $q$),

('flu_vaccine_gap',
 'Living patients with no flu vaccine in the last 12 months (anti-join)',
 $q$ SELECT p.patient_id FROM core.patients p
     WHERE p.death_date IS NULL
       AND NOT EXISTS (
           SELECT 1 FROM core.immunizations i
           WHERE i.patient_id = p.patient_id
             AND i.administered_ts >= (SELECT MAX(start_ts) FROM core.encounters)
                                      - INTERVAL '12 months') $q$),

('readmission_window',
 'Inpatient stays with the next admission per patient (readmissions)',
 $q$ SELECT patient_key, start_ts, stop_ts,
            LEAD(start_ts) OVER (PARTITION BY patient_key ORDER BY start_ts) AS next_admit
     FROM analytics.fact_encounters
     WHERE encounter_class = 'inpatient' $q$),

('recent_visits_last_90_days',
 'Visits in the last 90 days (an operations dashboard filter)',
 $q$ SELECT f.encounter_class, COUNT(*), SUM(f.total_claim_cost)
     FROM analytics.fact_encounters f
     WHERE f.start_date_key >= TO_CHAR(
               (SELECT MAX(start_ts) FROM analytics.fact_encounters) - INTERVAL '90 days',
               'YYYYMMDD')::integer
     GROUP BY f.encounter_class $q$);


-- =====================================================================
-- 2. BEFORE: time the workload with no extra indexes
-- =====================================================================
CALL perf.run_benchmarks('before');


-- =====================================================================
-- 3. Add indexes
-- =====================================================================

-- Composite index: filter by patient, then already sorted by time
CREATE INDEX ix_encounters_patient_start
    ON core.encounters (patient_id, start_ts DESC);

-- Covering index: INCLUDE value_numeric so A1C history is answered from
-- the index alone (an "index-only scan"), never touching the table
CREATE INDEX ix_observations_code_patient_ts
    ON core.observations (code, patient_id, observed_ts)
    INCLUDE (value_numeric);

-- Foreign key indexes (PostgreSQL does NOT add these automatically)
CREATE INDEX ix_conditions_patient   ON core.conditions  (patient_id);
CREATE INDEX ix_medications_patient  ON core.medications (patient_id, reason_code);
CREATE INDEX ix_immunizations_patient_ts
    ON core.immunizations (patient_id, administered_ts);

-- Partial index: only inpatient rows (a small slice of all visits)
CREATE INDEX ix_fact_enc_inpatient
    ON analytics.fact_encounters (patient_key, start_ts)
    INCLUDE (stop_ts)
    WHERE encounter_class = 'inpatient';

-- Warehouse join and filter keys
CREATE INDEX ix_fact_enc_start_date ON analytics.fact_encounters (start_date_key);
CREATE INDEX ix_fact_enc_patient    ON analytics.fact_encounters (patient_key);
CREATE INDEX ix_fact_diag_patient   ON analytics.fact_diagnoses  (patient_key);
-- SCD2 lookup: find the patient version in effect on a date
CREATE INDEX ix_dim_patient_lookup
    ON analytics.dim_patient (patient_id, effective_from, effective_to);

ANALYZE;


-- =====================================================================
-- 4. AFTER: time the same workload again
-- =====================================================================
CALL perf.run_benchmarks('after');


-- =====================================================================
-- 5. Partitioning: observations split into one partition per year
-- (built as a copy so the original table and its foreign keys are untouched)
-- =====================================================================
CREATE TABLE core.observations_by_year (
    observation_id BIGINT    NOT NULL,
    observed_ts    TIMESTAMP NOT NULL,
    patient_id     TEXT      NOT NULL,
    encounter_id   TEXT,
    category       TEXT,
    code           TEXT      NOT NULL,
    description    TEXT,
    value_text     TEXT,
    value_numeric  NUMERIC,
    units          TEXT,
    value_type     TEXT,
    PRIMARY KEY (observation_id, observed_ts)   -- must include the partition key
) PARTITION BY RANGE (observed_ts);

DO $$
DECLARE
    y INTEGER;
BEGIN
    FOR y IN
        SELECT generate_series(EXTRACT(YEAR FROM MIN(observed_ts))::int,
                               EXTRACT(YEAR FROM MAX(observed_ts))::int)
        FROM core.observations
    LOOP
        EXECUTE format(
            'CREATE TABLE core.observations_y%s PARTITION OF core.observations_by_year
             FOR VALUES FROM (%L) TO (%L)',
            y, make_date(y, 1, 1), make_date(y + 1, 1, 1));
    END LOOP;
END;
$$;

INSERT INTO core.observations_by_year
SELECT * FROM core.observations;

CREATE INDEX ON core.observations_by_year (code, observed_ts);
ANALYZE core.observations_by_year;

-- Benchmark: average systolic blood pressure in the latest calendar year.
-- Both queries get the identical date literal, so the comparison is fair.
INSERT INTO perf.benchmark_queries (query_name, purpose, query_sql)
SELECT v.query_name, v.purpose, format(v.template, r.year_start)
FROM (SELECT DATE_TRUNC('year', MAX(observed_ts))::date AS year_start
      FROM core.observations) r
CROSS JOIN (VALUES
    ('last_year_bp__unpartitioned',
     'Avg systolic BP in the latest year, original table',
     $q$ SELECT AVG(value_numeric) FROM core.observations
         WHERE code = '8480-6' AND observed_ts >= %L $q$),
    ('last_year_bp__partitioned',
     'Avg systolic BP in the latest year, partitioned table',
     $q$ SELECT AVG(value_numeric) FROM core.observations_by_year
         WHERE code = '8480-6' AND observed_ts >= %L $q$)
) AS v(query_name, purpose, template);

-- Both are measured once here (indexes already exist on both tables)
INSERT INTO perf.benchmark_results (query_name, run_label, runs, avg_ms)
SELECT query_name, 'after', 5, perf.time_query(query_sql, 5)
FROM perf.benchmark_queries
WHERE query_name LIKE 'last_year_bp__%';


-- =====================================================================
-- 6. Materialized view: precomputed monthly KPIs for a dashboard
-- =====================================================================
CREATE MATERIALIZED VIEW analytics.mv_monthly_kpis AS
SELECT d.year_month,
       COUNT(*)                                                   AS total_visits,
       COUNT(*) FILTER (WHERE f.encounter_class = 'emergency')    AS er_visits,
       COUNT(*) FILTER (WHERE f.encounter_class = 'inpatient')    AS inpatient_admissions,
       COUNT(DISTINCT f.patient_key)                              AS distinct_patients,
       ROUND(SUM(f.total_claim_cost), 2)                          AS total_cost,
       ROUND(AVG(f.total_claim_cost), 2)                          AS avg_cost_per_visit,
       ROUND(100.0 * SUM(f.payer_coverage)
             / NULLIF(SUM(f.total_claim_cost), 0), 1)             AS payer_coverage_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE NOT p.is_insured)
             / COUNT(*), 1)                                       AS uninsured_visit_pct
FROM analytics.fact_encounters f
JOIN analytics.dim_date  d ON d.date_key  = f.start_date_key
JOIN analytics.dim_payer p ON p.payer_key = f.payer_key
GROUP BY d.year_month;

-- A unique index lets the view refresh CONCURRENTLY (no read lock)
CREATE UNIQUE INDEX ON analytics.mv_monthly_kpis (year_month);

CREATE PROCEDURE analytics.refresh_dashboard_kpis()
LANGUAGE plpgsql
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_monthly_kpis;
    RAISE NOTICE 'mv_monthly_kpis refreshed at %', now();
END;
$$;

CALL analytics.refresh_dashboard_kpis();

-- Benchmark: dashboard KPIs computed live vs. read from the view
INSERT INTO perf.benchmark_queries (query_name, purpose, query_sql) VALUES
('monthly_kpis__live',
 'Monthly KPIs calculated from the fact table on every request',
 $q$ SELECT d.year_month, COUNT(*), COUNT(DISTINCT f.patient_key),
            SUM(f.total_claim_cost), AVG(f.total_claim_cost)
     FROM analytics.fact_encounters f
     JOIN analytics.dim_date  d ON d.date_key  = f.start_date_key
     JOIN analytics.dim_payer p ON p.payer_key = f.payer_key
     GROUP BY d.year_month $q$),
('monthly_kpis__materialized',
 'Monthly KPIs read from the materialized view',
 $q$ SELECT * FROM analytics.mv_monthly_kpis $q$);

INSERT INTO perf.benchmark_results (query_name, run_label, runs, avg_ms)
SELECT query_name, 'after', 5, perf.time_query(query_sql, 5)
FROM perf.benchmark_queries
WHERE query_name LIKE 'monthly_kpis__%';


-- =====================================================================
-- 7. Report A: index tuning, before vs after
-- =====================================================================
SELECT q.query_name,
       q.purpose,
       b.avg_ms                                        AS before_ms,
       a.avg_ms                                        AS after_ms,
       ROUND(b.avg_ms / NULLIF(a.avg_ms, 0), 1)        AS times_faster,
       ROUND(100 * (b.avg_ms - a.avg_ms) / NULLIF(b.avg_ms, 0), 1) AS pct_faster
FROM perf.benchmark_queries q
JOIN perf.benchmark_results b ON b.query_name = q.query_name AND b.run_label = 'before'
JOIN perf.benchmark_results a ON a.query_name = q.query_name AND a.run_label = 'after'
ORDER BY times_faster DESC;

-- Report B: partitioning and materialized view comparisons
-- Query names look like 'last_year_bp__partitioned': the part after '__'
-- says which version it is. (Exact match, not LIKE: in LIKE, '_' is a
-- wildcard, so '%__partitioned' would also match 'unpartitioned'.)
WITH versions AS (
    SELECT split_part(query_name, '__', 1) AS comparison,
           split_part(query_name, '__', 2) AS version,
           avg_ms
    FROM perf.benchmark_results
    WHERE strpos(query_name, '__') > 0
)
SELECT comparison,
       MAX(avg_ms) FILTER (WHERE version IN ('unpartitioned', 'live'))       AS baseline_ms,
       MAX(avg_ms) FILTER (WHERE version IN ('partitioned', 'materialized')) AS optimized_ms,
       ROUND(MAX(avg_ms) FILTER (WHERE version IN ('unpartitioned', 'live'))
             / NULLIF(MAX(avg_ms) FILTER (WHERE version IN ('partitioned', 'materialized')), 0), 1)
                                                                            AS times_faster
FROM versions
GROUP BY comparison
ORDER BY comparison;

-- Report C: proof of partition pruning. Look for how many
-- observations_yXXXX partitions appear in the plan: only the recent ones.
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT AVG(value_numeric)
FROM core.observations_by_year
WHERE code = '8480-6'
  AND observed_ts >= CURRENT_DATE - INTERVAL '1 year';
