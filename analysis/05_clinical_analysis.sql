/* =====================================================================
   05_clinical_analysis.sql
   Phase 4a: Clinical analysis.

   Run after 04_build_warehouse.sql. Run this file BEFORE 06 and 07:
   it creates the helper view analytics.v_patient_current that they use.

   Tip: in pgAdmin, highlight one query and press F5 to run just that
   query. Each query has its own result.

   Questions answered
   Q1  What is the 30-day hospital readmission rate?
   Q2  Which admission reasons have the highest readmission rates?
   Q3  How long do readmission "chains" run?          (recursive CTE)
   Q4  How common are chronic diseases by age and gender?
   Q5  Are diabetic patients' A1C levels improving or worsening?
   Q6  Which living patients are overdue for a flu vaccine?
   Q7  Which chronic conditions most often occur together?
   ===================================================================== */


-- ---------------------------------------------------------------------
-- Helper view: one row per patient (current version) with age and
-- age band measured at the end of the data (the latest encounter date).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_patient_current AS
WITH ref AS (
    SELECT MAX(start_ts)::date AS ref_date FROM analytics.fact_encounters
)
SELECT
    p.patient_key,
    p.patient_id,
    p.gender,
    p.race,
    p.ethnicity,
    p.birth_date,
    p.death_date,
    p.death_date IS NULL AS is_alive,
    ref.ref_date,
    EXTRACT(YEAR FROM AGE(COALESCE(p.death_date, ref.ref_date), p.birth_date))::int AS age,
    CASE
        WHEN AGE(COALESCE(p.death_date, ref.ref_date), p.birth_date) < INTERVAL '18 years' THEN '0-17'
        WHEN AGE(COALESCE(p.death_date, ref.ref_date), p.birth_date) < INTERVAL '35 years' THEN '18-34'
        WHEN AGE(COALESCE(p.death_date, ref.ref_date), p.birth_date) < INTERVAL '50 years' THEN '35-49'
        WHEN AGE(COALESCE(p.death_date, ref.ref_date), p.birth_date) < INTERVAL '65 years' THEN '50-64'
        ELSE '65+'
    END AS age_band
FROM analytics.dim_patient p
CROSS JOIN ref
WHERE p.is_current
  AND p.patient_key <> -1;


-- =====================================================================
-- Q1. Overall 30-day readmission rate
-- A readmission = a new inpatient admission within 30 days of discharge.
-- Stays discharged in the last 30 days of the data are excluded, because
-- their 30-day follow-up window is not complete yet.
-- Techniques: CTEs, LEAD window function, FILTER
-- =====================================================================
WITH stays AS (
    SELECT dp.patient_id,
           f.encounter_id,
           f.start_ts,
           f.stop_ts,
           LEAD(f.start_ts) OVER (PARTITION BY dp.patient_id ORDER BY f.start_ts) AS next_admit_ts
    FROM analytics.fact_encounters f
    JOIN analytics.dim_patient dp ON dp.patient_key = f.patient_key
    WHERE f.encounter_class = 'inpatient'
      AND f.stop_ts IS NOT NULL
),
flagged AS (
    SELECT *,
           next_admit_ts >= stop_ts
           AND next_admit_ts <= stop_ts + INTERVAL '30 days' AS readmitted_30d
    FROM stays
    WHERE stop_ts <= (SELECT MAX(start_ts) FROM analytics.fact_encounters) - INTERVAL '30 days'
)
SELECT COUNT(*)                                       AS index_admissions,
       COUNT(*) FILTER (WHERE readmitted_30d)         AS readmissions_30d,
       ROUND(100.0 * COUNT(*) FILTER (WHERE readmitted_30d)
             / NULLIF(COUNT(*), 0), 2)                AS readmission_rate_pct,
       COUNT(DISTINCT patient_id)                     AS patients_admitted
FROM flagged;


-- =====================================================================
-- Q2. Readmission rate by admission reason (reasons with 5+ admissions)
-- Techniques: CTEs, LEAD, GROUP BY ... HAVING, RANK
-- =====================================================================
WITH stays AS (
    SELECT dp.patient_id,
           f.reason_condition_key,
           f.stop_ts,
           LEAD(f.start_ts) OVER (PARTITION BY dp.patient_id ORDER BY f.start_ts) AS next_admit_ts
    FROM analytics.fact_encounters f
    JOIN analytics.dim_patient dp ON dp.patient_key = f.patient_key
    WHERE f.encounter_class = 'inpatient'
      AND f.stop_ts IS NOT NULL
),
by_reason AS (
    SELECT c.description AS admission_reason,
           COUNT(*) AS admissions,
           COUNT(*) FILTER (WHERE s.next_admit_ts >= s.stop_ts
                              AND s.next_admit_ts <= s.stop_ts + INTERVAL '30 days') AS readmissions
    FROM stays s
    JOIN analytics.dim_condition c ON c.condition_key = s.reason_condition_key
    WHERE s.stop_ts <= (SELECT MAX(start_ts) FROM analytics.fact_encounters) - INTERVAL '30 days'
    GROUP BY c.description
    HAVING COUNT(*) >= 5
)
SELECT RANK() OVER (ORDER BY 1.0 * readmissions / admissions DESC) AS rank,
       admission_reason,
       admissions,
       readmissions,
       ROUND(100.0 * readmissions / admissions, 1) AS readmission_rate_pct
FROM by_reason
ORDER BY rank, admissions DESC
LIMIT 10;


-- =====================================================================
-- Q3. Readmission chains: admission -> readmission -> readmission ...
-- How many patients bounce back repeatedly?
-- Techniques: RECURSIVE CTE, LAG/LEAD
-- =====================================================================
WITH RECURSIVE stays AS (
    SELECT dp.patient_id,
           f.encounter_id,
           f.start_ts,
           f.stop_ts,
           LAG(f.stop_ts)       OVER w AS prev_discharge_ts,
           LEAD(f.encounter_id) OVER w AS next_encounter_id
    FROM analytics.fact_encounters f
    JOIN analytics.dim_patient dp ON dp.patient_key = f.patient_key
    WHERE f.encounter_class = 'inpatient'
      AND f.stop_ts IS NOT NULL
    WINDOW w AS (PARTITION BY dp.patient_id ORDER BY f.start_ts)
),
flagged AS (
    SELECT *,
           COALESCE(start_ts >= prev_discharge_ts
                    AND start_ts <= prev_discharge_ts + INTERVAL '30 days', FALSE) AS is_readmission
    FROM stays
),
chain AS (
    -- anchor: admissions that are NOT readmissions start a new chain
    SELECT encounter_id AS chain_start_id, encounter_id, next_encounter_id, 1 AS chain_length
    FROM flagged
    WHERE NOT is_readmission

    UNION ALL

    -- recursive step: follow the next admission while it is a readmission
    SELECT c.chain_start_id, f.encounter_id, f.next_encounter_id, c.chain_length + 1
    FROM chain c
    JOIN flagged f ON f.encounter_id = c.next_encounter_id
    WHERE f.is_readmission
),
chain_lengths AS (
    SELECT chain_start_id, MAX(chain_length) AS admissions_in_chain
    FROM chain
    GROUP BY chain_start_id
)
SELECT admissions_in_chain,
       COUNT(*) AS number_of_chains,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_chains
FROM chain_lengths
GROUP BY admissions_in_chain
ORDER BY admissions_in_chain;


-- =====================================================================
-- Q4. Chronic disease prevalence (% of living patients) by age band,
-- split by gender. Pivot-style report: one column per condition.
-- Techniques: conditional aggregation with FILTER (a pivot / crosstab),
-- EXISTS
-- =====================================================================
WITH patient_flags AS (
    SELECT pc.patient_id,
           pc.age_band,
           pc.gender,
           BOOL_OR(c.description ILIKE '%diabetes%'
                   AND c.description NOT ILIKE '%prediabetes%')     AS has_diabetes,
           BOOL_OR(c.description ILIKE '%hypertension%')            AS has_hypertension,
           BOOL_OR(c.description ILIKE '%hyperlipidemia%'
                   OR c.description ILIKE '%hypertriglyceridemia%') AS has_high_cholesterol,
           BOOL_OR(c.description ILIKE '%obesity%')                 AS has_obesity,
           BOOL_OR(c.description ILIKE '%asthma%')                  AS has_asthma,
           BOOL_OR(c.description ILIKE '%heart disease%')           AS has_heart_disease
    FROM analytics.v_patient_current pc
    LEFT JOIN analytics.dim_patient    dp ON dp.patient_id   = pc.patient_id
    LEFT JOIN analytics.fact_diagnoses fd ON fd.patient_key  = dp.patient_key
    LEFT JOIN analytics.dim_condition  c  ON c.condition_key = fd.condition_key
    WHERE pc.is_alive
    GROUP BY pc.patient_id, pc.age_band, pc.gender
)
SELECT age_band,
       gender,
       COUNT(*) AS patients,
       ROUND(100.0 * COUNT(*) FILTER (WHERE has_diabetes)         / COUNT(*), 1) AS diabetes_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE has_hypertension)     / COUNT(*), 1) AS hypertension_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE has_high_cholesterol) / COUNT(*), 1) AS high_cholesterol_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE has_obesity)          / COUNT(*), 1) AS obesity_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE has_asthma)           / COUNT(*), 1) AS asthma_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE has_heart_disease)    / COUNT(*), 1) AS heart_disease_pct
FROM patient_flags
GROUP BY age_band, gender
ORDER BY age_band, gender;


-- =====================================================================
-- Q5. Diabetes control: is each patient's A1C getting better or worse?
-- A1C (LOINC 4548-4) under 7% is the usual target for diabetic patients.
-- Techniques: window functions (ROW_NUMBER, LAG, FIRST_VALUE), CTEs
-- =====================================================================
WITH a1c AS (
    SELECT o.patient_id,
           o.observed_ts,
           o.value_numeric AS a1c_pct,
           LAG(o.value_numeric) OVER w                                      AS prev_a1c,
           FIRST_VALUE(o.value_numeric) OVER w                              AS first_a1c,
           ROW_NUMBER() OVER (PARTITION BY o.patient_id ORDER BY o.observed_ts DESC) AS recency,
           COUNT(*) OVER (PARTITION BY o.patient_id)                        AS readings
    FROM core.observations o
    WHERE o.code = '4548-4'
      AND o.value_numeric IS NOT NULL
    WINDOW w AS (PARTITION BY o.patient_id ORDER BY o.observed_ts)
),
per_patient AS (
    SELECT patient_id,
           readings,
           first_a1c,
           a1c_pct              AS latest_a1c,
           a1c_pct - first_a1c  AS total_change,
           CASE
               WHEN readings < 2                  THEN 'Only one reading'
               WHEN a1c_pct - first_a1c <= -0.5   THEN 'Improving'
               WHEN a1c_pct - first_a1c >=  0.5   THEN 'Worsening'
               ELSE 'Stable'
           END AS trend
    FROM a1c
    WHERE recency = 1                  -- keep each patient's latest reading
)
SELECT trend,
       COUNT(*)                                              AS patients,
       ROUND(AVG(first_a1c), 2)                              AS avg_first_a1c,
       ROUND(AVG(latest_a1c), 2)                             AS avg_latest_a1c,
       ROUND(100.0 * COUNT(*) FILTER (WHERE latest_a1c >= 7)
             / COUNT(*), 1)                                  AS pct_above_7_target
FROM per_patient
GROUP BY trend
ORDER BY patients DESC;


-- =====================================================================
-- Q6. Preventive care gap: living patients with no flu vaccine in the
-- 12 months before the end of the data, by age band.
-- Techniques: anti-join with NOT EXISTS, date arithmetic
-- =====================================================================
SELECT pc.age_band,
       COUNT(*) AS living_patients,
       COUNT(*) FILTER (WHERE NOT EXISTS (
           SELECT 1
           FROM core.immunizations i
           WHERE i.patient_id = pc.patient_id
             AND i.description ILIKE '%influenza%'
             AND i.administered_ts >= pc.ref_date - INTERVAL '12 months'
       )) AS overdue_for_flu_vaccine,
       ROUND(100.0 * COUNT(*) FILTER (WHERE NOT EXISTS (
           SELECT 1
           FROM core.immunizations i
           WHERE i.patient_id = pc.patient_id
             AND i.description ILIKE '%influenza%'
             AND i.administered_ts >= pc.ref_date - INTERVAL '12 months'
       )) / COUNT(*), 1) AS pct_overdue
FROM analytics.v_patient_current pc
WHERE pc.is_alive
GROUP BY ROLLUP (pc.age_band)          -- adds an all-ages total row
ORDER BY pc.age_band NULLS LAST;


-- =====================================================================
-- Q7. Most common pairs of active chronic conditions (comorbidities)
-- Social and administrative "findings" are excluded; only disorders.
-- Techniques: self-join, COUNT DISTINCT, DENSE_RANK
-- =====================================================================
WITH active_disorders AS (
    SELECT DISTINCT dp.patient_id, fd.condition_key, c.description
    FROM analytics.fact_diagnoses fd
    JOIN analytics.dim_patient   dp ON dp.patient_key  = fd.patient_key
    JOIN analytics.dim_condition c  ON c.condition_key = fd.condition_key
    WHERE fd.is_active
      AND c.description NOT ILIKE '%(finding)%'
      AND c.description NOT ILIKE '%(situation)%'
      AND c.description NOT ILIKE '%(person)%'
)
SELECT DENSE_RANK() OVER (ORDER BY COUNT(DISTINCT a.patient_id) DESC) AS rank,
       a.description AS condition_1,
       b.description AS condition_2,
       COUNT(DISTINCT a.patient_id) AS patients_with_both
FROM active_disorders a
JOIN active_disorders b
  ON  b.patient_id    = a.patient_id
  AND b.condition_key > a.condition_key        -- each pair once, no self-pairs
GROUP BY a.description, b.description
ORDER BY patients_with_both DESC, condition_1, condition_2
LIMIT 10;
