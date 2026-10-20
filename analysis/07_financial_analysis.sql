/* =====================================================================
   07_financial_analysis.sql
   Phase 4c: Financial analysis.

   Run after 05_clinical_analysis.sql (uses analytics.v_patient_current).
   Tip: highlight one query and press F5 to run just that query.

   Costs are encounter claim costs (fact_encounters.total_claim_cost).

   Questions answered
   Q1  What is the payer mix, and how much does each payer cover?
   Q2  How much more do uninsured patients pay out of pocket?
   Q3  How fast are costs growing year over year?
   Q4  How concentrated is spending? (the Pareto / 80-20 question)
   Q5  Which medications cost the most, and who pays for them?
   Q6  How much do 30-day readmissions cost?
   ===================================================================== */


-- =====================================================================
-- Q1. Payer mix: visits, cost and coverage per payer, with a total row
-- Techniques: GROUP BY ROLLUP, GROUPING(), shares with SUM() OVER
-- =====================================================================
SELECT CASE WHEN GROUPING(p.name) = 1 THEN 'ALL PAYERS' ELSE p.name END AS payer,
       COUNT(*)                                             AS visits,
       ROUND(SUM(f.total_claim_cost), 0)                    AS total_cost,
       ROUND(SUM(f.payer_coverage), 0)                      AS paid_by_payer,
       ROUND(SUM(f.patient_paid), 0)                        AS paid_by_patients,
       ROUND(100.0 * SUM(f.payer_coverage)
             / NULLIF(SUM(f.total_claim_cost), 0), 1)       AS coverage_pct,
       ROUND(AVG(f.total_claim_cost), 2)                    AS avg_cost_per_visit
FROM analytics.fact_encounters f
JOIN analytics.dim_payer p ON p.payer_key = f.payer_key
GROUP BY ROLLUP (p.name)
ORDER BY GROUPING(p.name), total_cost DESC;


-- =====================================================================
-- Q2. Out-of-pocket burden: insured vs uninsured, by encounter type.
-- Pivot-style: insured and uninsured side by side.
-- Techniques: conditional aggregation (AVG ... FILTER), ratio of groups
-- =====================================================================
SELECT f.encounter_class,
       COUNT(*) FILTER (WHERE p.is_insured)                                AS insured_visits,
       COUNT(*) FILTER (WHERE NOT p.is_insured)                            AS uninsured_visits,
       ROUND(AVG(f.patient_paid) FILTER (WHERE p.is_insured), 2)           AS insured_avg_out_of_pocket,
       ROUND(AVG(f.patient_paid) FILTER (WHERE NOT p.is_insured), 2)       AS uninsured_avg_out_of_pocket,
       ROUND(AVG(f.patient_paid) FILTER (WHERE NOT p.is_insured)
             / NULLIF(AVG(f.patient_paid) FILTER (WHERE p.is_insured), 0), 1)
                                                                           AS uninsured_pay_x_times_more
FROM analytics.fact_encounters f
JOIN analytics.dim_payer p ON p.payer_key = f.payer_key
WHERE f.payer_key <> -1
GROUP BY f.encounter_class
ORDER BY uninsured_avg_out_of_pocket DESC NULLS LAST;


-- =====================================================================
-- Q3. Year-over-year cost growth by encounter type (last 6 years)
-- Techniques: LAG window function, percentage change, CTE
-- =====================================================================
WITH yearly AS (
    SELECT d.year,
           f.encounter_class,
           SUM(f.total_claim_cost) AS total_cost,
           COUNT(*)                AS visits
    FROM analytics.fact_encounters f
    JOIN analytics.dim_date d ON d.date_key = f.start_date_key
    GROUP BY d.year, f.encounter_class
),
with_prior AS (
    SELECT *,
           LAG(total_cost) OVER (PARTITION BY encounter_class ORDER BY year) AS prior_year_cost
    FROM yearly
)
SELECT year,
       encounter_class,
       visits,
       ROUND(total_cost, 0)       AS total_cost,
       ROUND(prior_year_cost, 0)  AS prior_year_cost,
       ROUND(100.0 * (total_cost - prior_year_cost)
             / NULLIF(prior_year_cost, 0), 1) AS yoy_growth_pct
FROM with_prior
WHERE year > (SELECT MAX(year) FROM yearly) - 6
  AND year < (SELECT MAX(year) FROM yearly)      -- the latest year is usually partial
ORDER BY encounter_class, year;


-- =====================================================================
-- Q4. Spending concentration: what share of patients drives half of
-- all costs? Also cost tiers (quartiles) of patients.
-- Techniques: running total with SUM() OVER (ORDER BY ...), PERCENT_RANK,
-- NTILE
-- =====================================================================
WITH patient_cost AS (
    SELECT dp.patient_id, SUM(f.total_claim_cost) AS lifetime_cost
    FROM analytics.fact_encounters f
    JOIN analytics.dim_patient dp ON dp.patient_key = f.patient_key
    GROUP BY dp.patient_id
),
ranked AS (
    SELECT patient_id,
           lifetime_cost,
           SUM(lifetime_cost) OVER (ORDER BY lifetime_cost DESC, patient_id)
               / SUM(lifetime_cost) OVER ()                     AS cumulative_cost_share,
           ROW_NUMBER() OVER (ORDER BY lifetime_cost DESC, patient_id)
               * 1.0 / COUNT(*) OVER ()                         AS cumulative_patient_share
    FROM patient_cost
)
SELECT ROUND(100 * MIN(cumulative_patient_share), 1) AS pct_of_patients_driving_50pct_of_cost,
       ROUND(100 * MIN(cumulative_patient_share) FILTER (WHERE cumulative_cost_share >= 0.8), 1)
                                                     AS pct_of_patients_driving_80pct_of_cost
FROM ranked
WHERE cumulative_cost_share >= 0.5;

-- Q4 Part B: patients grouped into cost quartiles
WITH patient_cost AS (
    SELECT dp.patient_id, SUM(f.total_claim_cost) AS lifetime_cost
    FROM analytics.fact_encounters f
    JOIN analytics.dim_patient dp ON dp.patient_key = f.patient_key
    GROUP BY dp.patient_id
),
tiered AS (
    SELECT *, NTILE(4) OVER (ORDER BY lifetime_cost DESC) AS quartile
    FROM patient_cost
)
SELECT CASE quartile WHEN 1 THEN 'Q1 (highest cost)' WHEN 2 THEN 'Q2'
                     WHEN 3 THEN 'Q3' ELSE 'Q4 (lowest cost)' END AS cost_tier,
       COUNT(*)                                                    AS patients,
       ROUND(AVG(lifetime_cost), 0)                                AS avg_lifetime_cost,
       ROUND(100.0 * SUM(lifetime_cost) / SUM(SUM(lifetime_cost)) OVER (), 1) AS pct_of_total_cost
FROM tiered
GROUP BY quartile
ORDER BY quartile;


-- =====================================================================
-- Q5. Top 10 medications by total cost, with payer share and cost per
-- dispense.
-- Techniques: aggregation, ratios, RANK
-- =====================================================================
SELECT RANK() OVER (ORDER BY SUM(total_cost) DESC)          AS rank,
       medication_name,
       COUNT(DISTINCT patient_key)                          AS patients,
       SUM(dispenses)                                       AS dispenses,
       ROUND(SUM(total_cost), 0)                            AS total_cost,
       ROUND(SUM(total_cost) / NULLIF(SUM(dispenses), 0), 2) AS cost_per_dispense,
       ROUND(100.0 * SUM(payer_coverage)
             / NULLIF(SUM(total_cost), 0), 1)               AS payer_covered_pct
FROM analytics.fact_medications
GROUP BY medication_name
ORDER BY rank
LIMIT 10;


-- =====================================================================
-- Q6. The cost of 30-day readmissions: what share of inpatient spending
-- goes to patients coming back within 30 days?
-- Techniques: LAG, CTE, conditional SUM
-- =====================================================================
WITH stays AS (
    SELECT f.total_claim_cost,
           f.start_ts,
           LAG(f.stop_ts) OVER (PARTITION BY dp.patient_id ORDER BY f.start_ts) AS prev_discharge_ts
    FROM analytics.fact_encounters f
    JOIN analytics.dim_patient dp ON dp.patient_key = f.patient_key
    WHERE f.encounter_class = 'inpatient'
),
flagged AS (
    SELECT *,
           COALESCE(start_ts >= prev_discharge_ts
                    AND start_ts <= prev_discharge_ts + INTERVAL '30 days', FALSE) AS is_readmission
    FROM stays
)
SELECT COUNT(*)                                                AS inpatient_stays,
       COUNT(*) FILTER (WHERE is_readmission)                  AS readmission_stays,
       ROUND(SUM(total_claim_cost), 0)                         AS total_inpatient_cost,
       ROUND(SUM(total_claim_cost) FILTER (WHERE is_readmission), 0) AS readmission_cost,
       ROUND(100.0 * SUM(total_claim_cost) FILTER (WHERE is_readmission)
             / NULLIF(SUM(total_claim_cost), 0), 1)            AS readmission_pct_of_inpatient_cost,
       ROUND(AVG(total_claim_cost) FILTER (WHERE is_readmission), 0) AS avg_cost_per_readmission
FROM flagged;
