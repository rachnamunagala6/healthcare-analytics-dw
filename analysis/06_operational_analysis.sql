/* =====================================================================
   06_operational_analysis.sql
   Phase 4b: Operational analysis.

   Run after 05_clinical_analysis.sql (uses analytics.v_patient_current).
   Tip: highlight one query and press F5 to run just that query.

   Questions answered
   Q1  How is visit volume trending month to month?
   Q2  How long do visits and stays last, by type?   (median, 90th pct)
   Q3  Which providers carry the most load in each organization?
   Q4  Who are the ER "high utilizers", and what brings them in?
   Q5  Which days of the week are busiest for the ER?
   Q6  Visit volume by year and type, with subtotals.
   ===================================================================== */


-- =====================================================================
-- Q1. Monthly visit volume by encounter type over the last 3 years,
-- with a 3-month moving average to smooth out noise.
-- Techniques: window frame (ROWS BETWEEN), dim_date join, CTE
-- =====================================================================
WITH monthly AS (
    SELECT d.year_month,
           f.encounter_class,
           COUNT(*) AS visits
    FROM analytics.fact_encounters f
    JOIN analytics.dim_date d ON d.date_key = f.start_date_key
    WHERE f.start_ts >= (SELECT MAX(start_ts) FROM analytics.fact_encounters) - INTERVAL '3 years'
    GROUP BY d.year_month, f.encounter_class
)
SELECT year_month,
       encounter_class,
       visits,
       ROUND(AVG(visits) OVER (PARTITION BY encounter_class
                               ORDER BY year_month
                               ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 1) AS moving_avg_3m
FROM monthly
ORDER BY encounter_class, year_month;


-- =====================================================================
-- Q2. Length of stay by encounter type: average, median, 90th percentile
-- (Medians matter here: a few very long stays inflate the average.)
-- Techniques: PERCENTILE_CONT ... WITHIN GROUP (ordered-set aggregates)
-- =====================================================================
SELECT encounter_class,
       COUNT(*)                                                         AS visits,
       ROUND(AVG(length_of_stay_hours), 1)                              AS avg_hours,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP
             (ORDER BY length_of_stay_hours)::numeric, 1)               AS median_hours,
       ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP
             (ORDER BY length_of_stay_hours)::numeric, 1)               AS p90_hours,
       ROUND(MAX(length_of_stay_hours), 1)                              AS max_hours
FROM analytics.fact_encounters
WHERE length_of_stay_hours >= 0          -- negative stays are logged as data quality issues
GROUP BY encounter_class
ORDER BY median_hours DESC;


-- =====================================================================
-- Q3. Top 3 busiest providers within each organization, with each
-- provider's share of the organization's visits.
-- Techniques: DENSE_RANK with PARTITION BY, SUM() OVER for shares
-- =====================================================================
WITH provider_load AS (
    SELECT o.name       AS organization,
           pr.name      AS provider,
           pr.specialty,
           COUNT(*)     AS visits,
           COUNT(DISTINCT f.patient_key) AS distinct_patients
    FROM analytics.fact_encounters  f
    JOIN analytics.dim_provider     pr ON pr.provider_key     = f.provider_key
    JOIN analytics.dim_organization o  ON o.organization_key  = f.organization_key
    WHERE f.provider_key <> -1
    GROUP BY o.name, pr.name, pr.specialty
),
ranked AS (
    SELECT *,
           DENSE_RANK() OVER (PARTITION BY organization ORDER BY visits DESC) AS rank_in_org,
           ROUND(100.0 * visits / SUM(visits) OVER (PARTITION BY organization), 1) AS pct_of_org_visits,
           SUM(visits) OVER (PARTITION BY organization)                            AS org_total_visits
    FROM provider_load
)
SELECT organization, rank_in_org, provider, specialty, visits,
       distinct_patients, pct_of_org_visits
FROM ranked
WHERE rank_in_org <= 3
ORDER BY org_total_visits DESC, organization, rank_in_org
LIMIT 30;


-- =====================================================================
-- Q4. ER high utilizers: the top 5% of patients by ER visits.
-- Part A: what share of all ER visits and ER cost do they account for?
-- Techniques: NTILE, CTEs, conditional aggregation
-- =====================================================================
WITH er_by_patient AS (
    SELECT dp.patient_id,
           COUNT(*)                AS er_visits,
           SUM(f.total_claim_cost) AS er_cost
    FROM analytics.fact_encounters f
    JOIN analytics.dim_patient dp ON dp.patient_key = f.patient_key
    WHERE f.encounter_class = 'emergency'
    GROUP BY dp.patient_id
),
tiered AS (
    SELECT *, NTILE(20) OVER (ORDER BY er_visits DESC, er_cost DESC) AS ventile
    FROM er_by_patient
)
SELECT CASE WHEN ventile = 1 THEN 'Top 5% (high utilizers)' ELSE 'Other 95%' END AS patient_group,
       COUNT(*)                                                    AS patients,
       SUM(er_visits)                                              AS er_visits,
       ROUND(AVG(er_visits), 1)                                    AS avg_er_visits_per_patient,
       ROUND(100.0 * SUM(er_visits) / SUM(SUM(er_visits)) OVER (), 1) AS pct_of_all_er_visits,
       ROUND(100.0 * SUM(er_cost)   / SUM(SUM(er_cost))   OVER (), 1) AS pct_of_all_er_cost
FROM tiered
GROUP BY (ventile = 1)
ORDER BY patient_group DESC;

-- Q4 Part B: the most common reasons for ER visits among high utilizers
WITH er_by_patient AS (
    SELECT dp.patient_id, COUNT(*) AS er_visits
    FROM analytics.fact_encounters f
    JOIN analytics.dim_patient dp ON dp.patient_key = f.patient_key
    WHERE f.encounter_class = 'emergency'
    GROUP BY dp.patient_id
),
high_utilizers AS (
    SELECT patient_id
    FROM (SELECT patient_id, NTILE(20) OVER (ORDER BY er_visits DESC) AS ventile
          FROM er_by_patient) t
    WHERE ventile = 1
)
SELECT COALESCE(NULLIF(c.description, 'Not recorded'), f.encounter_description) AS er_visit_reason,
       COUNT(*) AS er_visits,
       COUNT(DISTINCT dp.patient_id) AS patients
FROM analytics.fact_encounters f
JOIN analytics.dim_patient   dp ON dp.patient_key  = f.patient_key
JOIN analytics.dim_condition c  ON c.condition_key = f.reason_condition_key
WHERE f.encounter_class = 'emergency'
  AND dp.patient_id IN (SELECT patient_id FROM high_utilizers)
GROUP BY 1
ORDER BY er_visits DESC
LIMIT 10;


-- =====================================================================
-- Q5. ER visits by day of week, with each day's share and an index
-- versus the average day (100 = average).
-- Techniques: dim_date attributes, SUM() OVER / AVG() OVER on aggregates
-- =====================================================================
SELECT d.day_of_week,
       d.day_name,
       COUNT(*) AS er_visits,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_week,
       ROUND(100.0 * COUNT(*) / AVG(COUNT(*)) OVER (), 0) AS index_vs_avg_day
FROM analytics.fact_encounters f
JOIN analytics.dim_date d ON d.date_key = f.start_date_key
WHERE f.encounter_class = 'emergency'
GROUP BY d.day_of_week, d.day_name
ORDER BY d.day_of_week;


-- =====================================================================
-- Q6. Visits by year and encounter type for the last 5 years, with
-- a subtotal per year and a grand total.
-- Techniques: GROUP BY ROLLUP, GROUPING() to label subtotal rows
-- =====================================================================
SELECT CASE WHEN GROUPING(d.year) = 1 THEN 'ALL YEARS'
            ELSE d.year::text END                          AS year,
       CASE WHEN GROUPING(d.year) = 1 THEN 'GRAND TOTAL'
            WHEN GROUPING(f.encounter_class) = 1 THEN 'Year subtotal'
            ELSE f.encounter_class END                     AS encounter_class,
       COUNT(*)                                            AS visits,
       ROUND(SUM(f.total_claim_cost), 0)                   AS total_cost
FROM analytics.fact_encounters f
JOIN analytics.dim_date d ON d.date_key = f.start_date_key
WHERE d.year > (SELECT MAX(year) FROM analytics.dim_date d2
                JOIN analytics.fact_encounters f2 ON f2.start_date_key = d2.date_key) - 5
GROUP BY ROLLUP (d.year, f.encounter_class)
ORDER BY GROUPING(d.year), d.year, GROUPING(f.encounter_class), visits DESC;
