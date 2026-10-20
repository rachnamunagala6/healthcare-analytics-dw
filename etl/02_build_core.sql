/* =====================================================================
   02_build_core.sql
   Phase 1 (part 2): Transform raw staging data into the core schema.

   What this script does:
   - Converts TEXT columns into proper types (DATE, TIMESTAMP, NUMERIC)
   - Converts empty strings to NULL
   - Adds primary keys, foreign keys and CHECK constraints
   - Uses surrogate keys (BIGINT IDENTITY) for tables with no natural id
   - Keeps clinical codes (SNOMED, RxNorm, LOINC) as TEXT, since they are
     identifiers, not numbers
   - Leaves direct identifiers (SSN, driver's license, passport) out of
     core on purpose: they stay in staging only (privacy by design)
   - Secondary indexes are deliberately NOT created here; they are added
     and benchmarked in Phase 5 (performance)

   Re-runnable: drops and rebuilds every core table.
   Run while connected to the healthcare_dw database.
   ===================================================================== */

-- ---------------------------------------------------------------------
-- 0. Drop existing core tables (children first)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS core.careplans          CASCADE;
DROP TABLE IF EXISTS core.allergies          CASCADE;
DROP TABLE IF EXISTS core.immunizations      CASCADE;
DROP TABLE IF EXISTS core.observations       CASCADE;
DROP TABLE IF EXISTS core.procedures         CASCADE;
DROP TABLE IF EXISTS core.medications        CASCADE;
DROP TABLE IF EXISTS core.conditions         CASCADE;
DROP TABLE IF EXISTS core.encounters         CASCADE;
DROP TABLE IF EXISTS core.payer_transitions  CASCADE;
DROP TABLE IF EXISTS core.providers          CASCADE;
DROP TABLE IF EXISTS core.payers             CASCADE;
DROP TABLE IF EXISTS core.organizations      CASCADE;
DROP TABLE IF EXISTS core.patients           CASCADE;


-- =====================================================================
-- 1. Entity tables
-- =====================================================================

CREATE TABLE core.patients (
    patient_id          TEXT PRIMARY KEY,
    birth_date          DATE NOT NULL,
    death_date          DATE,
    first_name          TEXT,
    last_name           TEXT,
    marital_status      TEXT,
    race                TEXT,
    ethnicity           TEXT,
    gender              CHAR(1) NOT NULL CHECK (gender IN ('M', 'F')),
    city                TEXT,
    state               TEXT,
    county              TEXT,
    zip                 TEXT,
    lat                 NUMERIC(9,6),
    lon                 NUMERIC(9,6),
    healthcare_expenses NUMERIC(14,2),
    healthcare_coverage NUMERIC(14,2),
    income              NUMERIC(12,2)
);

INSERT INTO core.patients
SELECT
    id,
    birthdate::date,
    NULLIF(deathdate, '')::date,
    NULLIF(first, ''),
    NULLIF(last, ''),
    NULLIF(marital, ''),
    NULLIF(race, ''),
    NULLIF(ethnicity, ''),
    gender,
    NULLIF(city, ''),
    NULLIF(state, ''),
    NULLIF(county, ''),
    NULLIF(zip, ''),
    NULLIF(lat, '')::numeric,
    NULLIF(lon, '')::numeric,
    NULLIF(healthcare_expenses, '')::numeric,
    NULLIF(healthcare_coverage, '')::numeric,
    NULLIF(income, '')::numeric
FROM staging.patients;


CREATE TABLE core.organizations (
    organization_id TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    city            TEXT,
    state           TEXT,
    zip             TEXT,
    lat             NUMERIC(9,6),
    lon             NUMERIC(9,6),
    revenue         NUMERIC(14,2),
    utilization     INTEGER
);

INSERT INTO core.organizations
SELECT
    id,
    name,
    NULLIF(city, ''),
    NULLIF(state, ''),
    NULLIF(zip, ''),
    NULLIF(lat, '')::numeric,
    NULLIF(lon, '')::numeric,
    NULLIF(revenue, '')::numeric,
    NULLIF(utilization, '')::integer
FROM staging.organizations;


CREATE TABLE core.providers (
    provider_id     TEXT PRIMARY KEY,
    organization_id TEXT NOT NULL REFERENCES core.organizations (organization_id),
    name            TEXT NOT NULL,
    gender          CHAR(1),
    specialty       TEXT,
    city            TEXT,
    state           TEXT,
    zip             TEXT
);

INSERT INTO core.providers
SELECT
    id,
    organization,
    name,
    NULLIF(gender, ''),
    NULLIF(speciality, ''),   -- Synthea spells it "speciality"
    NULLIF(city, ''),
    NULLIF(state, ''),
    NULLIF(zip, '')
FROM staging.providers;


CREATE TABLE core.payers (
    payer_id   TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    ownership  TEXT,
    state_hq   TEXT
);

INSERT INTO core.payers
SELECT
    id,
    name,
    NULLIF(ownership, ''),
    NULLIF(state_headquartered, '')
FROM staging.payers;


CREATE TABLE core.payer_transitions (
    payer_transition_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id          TEXT NOT NULL REFERENCES core.patients (patient_id),
    member_id           TEXT,
    start_date          TIMESTAMP NOT NULL,
    end_date            TIMESTAMP,
    payer_id            TEXT REFERENCES core.payers (payer_id),
    secondary_payer_id  TEXT REFERENCES core.payers (payer_id),
    plan_ownership      TEXT
);

INSERT INTO core.payer_transitions
    (patient_id, member_id, start_date, end_date, payer_id,
     secondary_payer_id, plan_ownership)
SELECT
    patient,
    NULLIF(memberid, ''),
    start_date::timestamp,
    NULLIF(end_date, '')::timestamp,
    NULLIF(payer, ''),
    NULLIF(secondary_payer, ''),
    NULLIF(plan_ownership, '')
FROM staging.payer_transitions;


-- =====================================================================
-- 2. Encounters (the central fact of the clinical data)
-- =====================================================================

CREATE TABLE core.encounters (
    encounter_id        TEXT PRIMARY KEY,
    start_ts            TIMESTAMP NOT NULL,
    stop_ts             TIMESTAMP,
    patient_id          TEXT NOT NULL REFERENCES core.patients (patient_id),
    organization_id     TEXT REFERENCES core.organizations (organization_id),
    provider_id         TEXT REFERENCES core.providers (provider_id),
    payer_id            TEXT REFERENCES core.payers (payer_id),
    encounter_class     TEXT NOT NULL,
    code                TEXT,
    description         TEXT,
    base_encounter_cost NUMERIC(12,2) CHECK (base_encounter_cost >= 0),
    total_claim_cost    NUMERIC(12,2) CHECK (total_claim_cost >= 0),
    payer_coverage      NUMERIC(12,2) CHECK (payer_coverage >= 0),
    reason_code         TEXT,
    reason_description  TEXT
);

INSERT INTO core.encounters
SELECT
    id,
    start::timestamp,
    NULLIF(stop, '')::timestamp,
    patient,
    NULLIF(organization, ''),
    NULLIF(provider, ''),
    NULLIF(payer, ''),
    encounterclass,
    NULLIF(code, ''),
    NULLIF(description, ''),
    NULLIF(base_encounter_cost, '')::numeric,
    NULLIF(total_claim_cost, '')::numeric,
    NULLIF(payer_coverage, '')::numeric,
    NULLIF(reasoncode, ''),
    NULLIF(reasondescription, '')
FROM staging.encounters;


-- =====================================================================
-- 3. Clinical event tables
-- =====================================================================

CREATE TABLE core.conditions (
    condition_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    start_date    DATE NOT NULL,
    stop_date     DATE,
    patient_id    TEXT NOT NULL REFERENCES core.patients (patient_id),
    encounter_id  TEXT REFERENCES core.encounters (encounter_id),
    code_system   TEXT,
    code          TEXT NOT NULL,
    description   TEXT
);

INSERT INTO core.conditions
    (start_date, stop_date, patient_id, encounter_id, code_system, code, description)
SELECT
    start::date,
    NULLIF(stop, '')::date,
    patient,
    NULLIF(encounter, ''),
    NULLIF(system, ''),
    code,
    NULLIF(description, '')
FROM staging.conditions;


CREATE TABLE core.medications (
    medication_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    start_ts           TIMESTAMP NOT NULL,
    stop_ts            TIMESTAMP,
    patient_id         TEXT NOT NULL REFERENCES core.patients (patient_id),
    payer_id           TEXT REFERENCES core.payers (payer_id),
    encounter_id       TEXT REFERENCES core.encounters (encounter_id),
    code               TEXT NOT NULL,
    description        TEXT,
    base_cost          NUMERIC(12,2) CHECK (base_cost >= 0),
    payer_coverage     NUMERIC(12,2) CHECK (payer_coverage >= 0),
    dispenses          INTEGER CHECK (dispenses >= 0),
    total_cost         NUMERIC(14,2) CHECK (total_cost >= 0),
    reason_code        TEXT,
    reason_description TEXT
);

INSERT INTO core.medications
    (start_ts, stop_ts, patient_id, payer_id, encounter_id, code, description,
     base_cost, payer_coverage, dispenses, total_cost, reason_code, reason_description)
SELECT
    start::timestamp,
    NULLIF(stop, '')::timestamp,
    patient,
    NULLIF(payer, ''),
    NULLIF(encounter, ''),
    code,
    NULLIF(description, ''),
    NULLIF(base_cost, '')::numeric,
    NULLIF(payer_coverage, '')::numeric,
    NULLIF(dispenses, '')::integer,
    NULLIF(totalcost, '')::numeric,
    NULLIF(reasoncode, ''),
    NULLIF(reasondescription, '')
FROM staging.medications;


CREATE TABLE core.procedures (
    procedure_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    start_ts           TIMESTAMP NOT NULL,
    stop_ts            TIMESTAMP,
    patient_id         TEXT NOT NULL REFERENCES core.patients (patient_id),
    encounter_id       TEXT REFERENCES core.encounters (encounter_id),
    code_system        TEXT,
    code               TEXT NOT NULL,
    description        TEXT,
    base_cost          NUMERIC(12,2) CHECK (base_cost >= 0),
    reason_code        TEXT,
    reason_description TEXT
);

INSERT INTO core.procedures
    (start_ts, stop_ts, patient_id, encounter_id, code_system, code,
     description, base_cost, reason_code, reason_description)
SELECT
    start::timestamp,
    NULLIF(stop, '')::timestamp,
    patient,
    NULLIF(encounter, ''),
    NULLIF(system, ''),
    code,
    NULLIF(description, ''),
    NULLIF(base_cost, '')::numeric,
    NULLIF(reasoncode, ''),
    NULLIF(reasondescription, '')
FROM staging.procedures;


-- Observations hold both numeric results (e.g. blood pressure, A1C) and
-- text results (e.g. smoking status). Numeric values get their own column
-- so they can be averaged and compared.
CREATE TABLE core.observations (
    observation_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    observed_ts    TIMESTAMP NOT NULL,
    patient_id     TEXT NOT NULL REFERENCES core.patients (patient_id),
    encounter_id   TEXT REFERENCES core.encounters (encounter_id),
    category       TEXT,
    code           TEXT NOT NULL,
    description    TEXT,
    value_text     TEXT,
    value_numeric  NUMERIC,
    units          TEXT,
    value_type     TEXT
);

INSERT INTO core.observations
    (observed_ts, patient_id, encounter_id, category, code, description,
     value_text, value_numeric, units, value_type)
SELECT
    date::timestamp,
    patient,
    NULLIF(encounter, ''),
    NULLIF(category, ''),
    code,
    NULLIF(description, ''),
    NULLIF(value, ''),
    CASE
        WHEN type = 'numeric' AND value ~ '^-?[0-9]+(\.[0-9]+)?$'
        THEN value::numeric
    END,
    NULLIF(units, ''),
    NULLIF(type, '')
FROM staging.observations;


CREATE TABLE core.immunizations (
    immunization_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    administered_ts TIMESTAMP NOT NULL,
    patient_id      TEXT NOT NULL REFERENCES core.patients (patient_id),
    encounter_id    TEXT REFERENCES core.encounters (encounter_id),
    code            TEXT NOT NULL,
    description     TEXT,
    base_cost       NUMERIC(12,2) CHECK (base_cost >= 0)
);

INSERT INTO core.immunizations
    (administered_ts, patient_id, encounter_id, code, description, base_cost)
SELECT
    date::timestamp,
    patient,
    NULLIF(encounter, ''),
    code,
    NULLIF(description, ''),
    NULLIF(base_cost, '')::numeric
FROM staging.immunizations;


CREATE TABLE core.allergies (
    allergy_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    start_date    DATE NOT NULL,
    stop_date     DATE,
    patient_id    TEXT NOT NULL REFERENCES core.patients (patient_id),
    encounter_id  TEXT REFERENCES core.encounters (encounter_id),
    code          TEXT NOT NULL,
    code_system   TEXT,
    description   TEXT,
    allergy_type  TEXT,
    category      TEXT,
    reaction1     TEXT,
    severity1     TEXT
);

INSERT INTO core.allergies
    (start_date, stop_date, patient_id, encounter_id, code, code_system,
     description, allergy_type, category, reaction1, severity1)
SELECT
    start::date,
    NULLIF(stop, '')::date,
    patient,
    NULLIF(encounter, ''),
    code,
    NULLIF(system, ''),
    NULLIF(description, ''),
    NULLIF(type, ''),
    NULLIF(category, ''),
    NULLIF(description1, ''),
    NULLIF(severity1, '')
FROM staging.allergies;


CREATE TABLE core.careplans (
    careplan_id        TEXT PRIMARY KEY,
    start_date         DATE NOT NULL,
    stop_date          DATE,
    patient_id         TEXT NOT NULL REFERENCES core.patients (patient_id),
    encounter_id       TEXT REFERENCES core.encounters (encounter_id),
    code               TEXT NOT NULL,
    description        TEXT,
    reason_code        TEXT,
    reason_description TEXT
);

INSERT INTO core.careplans
SELECT
    id,
    start::date,
    NULLIF(stop, '')::date,
    patient,
    NULLIF(encounter, ''),
    code,
    NULLIF(description, ''),
    NULLIF(reasoncode, ''),
    NULLIF(reasondescription, '')
FROM staging.careplans;


-- =====================================================================
-- 4. Verify: staging vs core row counts (they should match)
-- =====================================================================

SELECT t.table_name, t.staging_rows, t.core_rows,
       CASE WHEN t.staging_rows = t.core_rows THEN 'OK' ELSE 'MISMATCH' END AS status
FROM (
              SELECT 'patients' AS table_name,
                     (SELECT COUNT(*) FROM staging.patients)          AS staging_rows,
                     (SELECT COUNT(*) FROM core.patients)             AS core_rows
    UNION ALL SELECT 'organizations',
                     (SELECT COUNT(*) FROM staging.organizations),
                     (SELECT COUNT(*) FROM core.organizations)
    UNION ALL SELECT 'providers',
                     (SELECT COUNT(*) FROM staging.providers),
                     (SELECT COUNT(*) FROM core.providers)
    UNION ALL SELECT 'payers',
                     (SELECT COUNT(*) FROM staging.payers),
                     (SELECT COUNT(*) FROM core.payers)
    UNION ALL SELECT 'payer_transitions',
                     (SELECT COUNT(*) FROM staging.payer_transitions),
                     (SELECT COUNT(*) FROM core.payer_transitions)
    UNION ALL SELECT 'encounters',
                     (SELECT COUNT(*) FROM staging.encounters),
                     (SELECT COUNT(*) FROM core.encounters)
    UNION ALL SELECT 'conditions',
                     (SELECT COUNT(*) FROM staging.conditions),
                     (SELECT COUNT(*) FROM core.conditions)
    UNION ALL SELECT 'medications',
                     (SELECT COUNT(*) FROM staging.medications),
                     (SELECT COUNT(*) FROM core.medications)
    UNION ALL SELECT 'procedures',
                     (SELECT COUNT(*) FROM staging.procedures),
                     (SELECT COUNT(*) FROM core.procedures)
    UNION ALL SELECT 'observations',
                     (SELECT COUNT(*) FROM staging.observations),
                     (SELECT COUNT(*) FROM core.observations)
    UNION ALL SELECT 'immunizations',
                     (SELECT COUNT(*) FROM staging.immunizations),
                     (SELECT COUNT(*) FROM core.immunizations)
    UNION ALL SELECT 'allergies',
                     (SELECT COUNT(*) FROM staging.allergies),
                     (SELECT COUNT(*) FROM core.allergies)
    UNION ALL SELECT 'careplans',
                     (SELECT COUNT(*) FROM staging.careplans),
                     (SELECT COUNT(*) FROM core.careplans)
) AS t
ORDER BY t.staging_rows DESC;
