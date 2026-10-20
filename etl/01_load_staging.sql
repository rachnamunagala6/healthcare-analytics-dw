/* =====================================================================
   01_load_staging.sql
   Phase 1: Load raw Synthea CSV files into the staging schema.

   Design notes:
   - Staging holds the raw data exactly as delivered. Every column is TEXT,
     so no row is rejected at load time. Type conversion, cleaning and keys
     are applied later when data moves from staging -> core.
   - The script is re-runnable: each table is dropped and rebuilt.
   - CSV files are read from /Users/Shared/synthea_csv/ (the PostgreSQL
     server process can read this folder on macOS).

   Run while connected to the healthcare_dw database.
   ===================================================================== */

SET search_path TO staging;

-- ---------------------------------------------------------------------
-- Reference / entity tables
-- ---------------------------------------------------------------------

DROP TABLE IF EXISTS patients;
CREATE TABLE patients (
    id TEXT, birthdate TEXT, deathdate TEXT, ssn TEXT, drivers TEXT,
    passport TEXT, prefix TEXT, first TEXT, middle TEXT, last TEXT,
    suffix TEXT, maiden TEXT, marital TEXT, race TEXT, ethnicity TEXT,
    gender TEXT, birthplace TEXT, address TEXT, city TEXT, state TEXT,
    county TEXT, fips TEXT, zip TEXT, lat TEXT, lon TEXT,
    healthcare_expenses TEXT, healthcare_coverage TEXT, income TEXT
);

DROP TABLE IF EXISTS organizations;
CREATE TABLE organizations (
    id TEXT, name TEXT, address TEXT, city TEXT, state TEXT, zip TEXT,
    lat TEXT, lon TEXT, phone TEXT, revenue TEXT, utilization TEXT, npi TEXT
);

DROP TABLE IF EXISTS providers;
CREATE TABLE providers (
    id TEXT, organization TEXT, name TEXT, gender TEXT, speciality TEXT,
    address TEXT, city TEXT, state TEXT, zip TEXT, lat TEXT, lon TEXT,
    encounters TEXT, procedures TEXT, npi TEXT
);

DROP TABLE IF EXISTS payers;
CREATE TABLE payers (
    id TEXT, name TEXT, ownership TEXT, address TEXT, city TEXT,
    state_headquartered TEXT, zip TEXT, phone TEXT, amount_covered TEXT,
    amount_uncovered TEXT, revenue TEXT, covered_encounters TEXT,
    uncovered_encounters TEXT, covered_medications TEXT,
    uncovered_medications TEXT, covered_procedures TEXT,
    uncovered_procedures TEXT, covered_immunizations TEXT,
    uncovered_immunizations TEXT, unique_customers TEXT, qols_avg TEXT,
    member_months TEXT
);

DROP TABLE IF EXISTS payer_transitions;
CREATE TABLE payer_transitions (
    patient TEXT, memberid TEXT, start_date TEXT, end_date TEXT, payer TEXT,
    secondary_payer TEXT, plan_ownership TEXT, owner_name TEXT
);

-- ---------------------------------------------------------------------
-- Clinical event tables
-- ---------------------------------------------------------------------

DROP TABLE IF EXISTS encounters;
CREATE TABLE encounters (
    id TEXT, start TEXT, stop TEXT, patient TEXT, organization TEXT,
    provider TEXT, payer TEXT, encounterclass TEXT, code TEXT,
    description TEXT, base_encounter_cost TEXT, total_claim_cost TEXT,
    payer_coverage TEXT, reasoncode TEXT, reasondescription TEXT
);

DROP TABLE IF EXISTS conditions;
CREATE TABLE conditions (
    start TEXT, stop TEXT, patient TEXT, encounter TEXT, system TEXT,
    code TEXT, description TEXT
);

DROP TABLE IF EXISTS medications;
CREATE TABLE medications (
    start TEXT, stop TEXT, patient TEXT, payer TEXT, encounter TEXT,
    code TEXT, description TEXT, base_cost TEXT, payer_coverage TEXT,
    dispenses TEXT, totalcost TEXT, reasoncode TEXT, reasondescription TEXT
);

DROP TABLE IF EXISTS procedures;
CREATE TABLE procedures (
    start TEXT, stop TEXT, patient TEXT, encounter TEXT, system TEXT,
    code TEXT, description TEXT, base_cost TEXT, reasoncode TEXT,
    reasondescription TEXT
);

DROP TABLE IF EXISTS observations;
CREATE TABLE observations (
    date TEXT, patient TEXT, encounter TEXT, category TEXT, code TEXT,
    description TEXT, value TEXT, units TEXT, type TEXT
);

DROP TABLE IF EXISTS immunizations;
CREATE TABLE immunizations (
    date TEXT, patient TEXT, encounter TEXT, code TEXT, description TEXT,
    base_cost TEXT
);

DROP TABLE IF EXISTS allergies;
CREATE TABLE allergies (
    start TEXT, stop TEXT, patient TEXT, encounter TEXT, code TEXT,
    system TEXT, description TEXT, type TEXT, category TEXT,
    reaction1 TEXT, description1 TEXT, severity1 TEXT,
    reaction2 TEXT, description2 TEXT, severity2 TEXT
);

DROP TABLE IF EXISTS careplans;
CREATE TABLE careplans (
    id TEXT, start TEXT, stop TEXT, patient TEXT, encounter TEXT,
    code TEXT, description TEXT, reasoncode TEXT, reasondescription TEXT
);

DROP TABLE IF EXISTS devices;
CREATE TABLE devices (
    start TEXT, stop TEXT, patient TEXT, encounter TEXT, code TEXT,
    description TEXT, udi TEXT
);

DROP TABLE IF EXISTS imaging_studies;
CREATE TABLE imaging_studies (
    id TEXT, date TEXT, patient TEXT, encounter TEXT, series_uid TEXT,
    bodysite_code TEXT, bodysite_description TEXT, modality_code TEXT,
    modality_description TEXT, instance_uid TEXT, sop_code TEXT,
    sop_description TEXT, procedure_code TEXT
);

DROP TABLE IF EXISTS supplies;
CREATE TABLE supplies (
    date TEXT, patient TEXT, encounter TEXT, code TEXT, description TEXT,
    quantity TEXT
);

-- ---------------------------------------------------------------------
-- Billing tables
-- ---------------------------------------------------------------------

DROP TABLE IF EXISTS claims;
CREATE TABLE claims (
    id TEXT, patientid TEXT, providerid TEXT, primarypatientinsuranceid TEXT,
    secondarypatientinsuranceid TEXT, departmentid TEXT,
    patientdepartmentid TEXT, diagnosis1 TEXT, diagnosis2 TEXT,
    diagnosis3 TEXT, diagnosis4 TEXT, diagnosis5 TEXT, diagnosis6 TEXT,
    diagnosis7 TEXT, diagnosis8 TEXT, referringproviderid TEXT,
    appointmentid TEXT, currentillnessdate TEXT, servicedate TEXT,
    supervisingproviderid TEXT, status1 TEXT, status2 TEXT, statusp TEXT,
    outstanding1 TEXT, outstanding2 TEXT, outstandingp TEXT,
    lastbilleddate1 TEXT, lastbilleddate2 TEXT, lastbilleddatep TEXT,
    healthcareclaimtypeid1 TEXT, healthcareclaimtypeid2 TEXT
);

DROP TABLE IF EXISTS claims_transactions;
CREATE TABLE claims_transactions (
    id TEXT, claimid TEXT, chargeid TEXT, patientid TEXT, type TEXT,
    amount TEXT, method TEXT, fromdate TEXT, todate TEXT,
    placeofservice TEXT, procedurecode TEXT, modifier1 TEXT, modifier2 TEXT,
    diagnosisref1 TEXT, diagnosisref2 TEXT, diagnosisref3 TEXT,
    diagnosisref4 TEXT, units TEXT, departmentid TEXT, notes TEXT,
    unitamount TEXT, transferoutid TEXT, transfertype TEXT, payments TEXT,
    adjustments TEXT, transfers TEXT, outstanding TEXT, appointmentid TEXT,
    linenote TEXT, patientinsuranceid TEXT, feescheduleid TEXT,
    providerid TEXT, supervisingproviderid TEXT
);

-- ---------------------------------------------------------------------
-- Load the CSV files
-- ---------------------------------------------------------------------

COPY patients            FROM '/Users/Shared/synthea_csv/patients.csv'            WITH (FORMAT csv, HEADER true);
COPY organizations       FROM '/Users/Shared/synthea_csv/organizations.csv'       WITH (FORMAT csv, HEADER true);
COPY providers           FROM '/Users/Shared/synthea_csv/providers.csv'           WITH (FORMAT csv, HEADER true);
COPY payers              FROM '/Users/Shared/synthea_csv/payers.csv'              WITH (FORMAT csv, HEADER true);
COPY payer_transitions   FROM '/Users/Shared/synthea_csv/payer_transitions.csv'   WITH (FORMAT csv, HEADER true);
COPY encounters          FROM '/Users/Shared/synthea_csv/encounters.csv'          WITH (FORMAT csv, HEADER true);
COPY conditions          FROM '/Users/Shared/synthea_csv/conditions.csv'          WITH (FORMAT csv, HEADER true);
COPY medications         FROM '/Users/Shared/synthea_csv/medications.csv'         WITH (FORMAT csv, HEADER true);
COPY procedures          FROM '/Users/Shared/synthea_csv/procedures.csv'          WITH (FORMAT csv, HEADER true);
COPY observations        FROM '/Users/Shared/synthea_csv/observations.csv'        WITH (FORMAT csv, HEADER true);
COPY immunizations       FROM '/Users/Shared/synthea_csv/immunizations.csv'       WITH (FORMAT csv, HEADER true);
COPY allergies           FROM '/Users/Shared/synthea_csv/allergies.csv'           WITH (FORMAT csv, HEADER true);
COPY careplans           FROM '/Users/Shared/synthea_csv/careplans.csv'           WITH (FORMAT csv, HEADER true);
COPY devices             FROM '/Users/Shared/synthea_csv/devices.csv'             WITH (FORMAT csv, HEADER true);
COPY imaging_studies     FROM '/Users/Shared/synthea_csv/imaging_studies.csv'     WITH (FORMAT csv, HEADER true);
COPY supplies            FROM '/Users/Shared/synthea_csv/supplies.csv'            WITH (FORMAT csv, HEADER true);
COPY claims              FROM '/Users/Shared/synthea_csv/claims.csv'              WITH (FORMAT csv, HEADER true);
COPY claims_transactions FROM '/Users/Shared/synthea_csv/claims_transactions.csv' WITH (FORMAT csv, HEADER true);

-- ---------------------------------------------------------------------
-- Verify: row count for every staging table
-- ---------------------------------------------------------------------

SELECT 'patients' AS table_name, COUNT(*) AS row_count FROM patients
UNION ALL SELECT 'organizations',       COUNT(*) FROM organizations
UNION ALL SELECT 'providers',           COUNT(*) FROM providers
UNION ALL SELECT 'payers',              COUNT(*) FROM payers
UNION ALL SELECT 'payer_transitions',   COUNT(*) FROM payer_transitions
UNION ALL SELECT 'encounters',          COUNT(*) FROM encounters
UNION ALL SELECT 'conditions',          COUNT(*) FROM conditions
UNION ALL SELECT 'medications',         COUNT(*) FROM medications
UNION ALL SELECT 'procedures',          COUNT(*) FROM procedures
UNION ALL SELECT 'observations',        COUNT(*) FROM observations
UNION ALL SELECT 'immunizations',       COUNT(*) FROM immunizations
UNION ALL SELECT 'allergies',           COUNT(*) FROM allergies
UNION ALL SELECT 'careplans',           COUNT(*) FROM careplans
UNION ALL SELECT 'devices',             COUNT(*) FROM devices
UNION ALL SELECT 'imaging_studies',     COUNT(*) FROM imaging_studies
UNION ALL SELECT 'supplies',            COUNT(*) FROM supplies
UNION ALL SELECT 'claims',              COUNT(*) FROM claims
UNION ALL SELECT 'claims_transactions', COUNT(*) FROM claims_transactions
ORDER BY row_count DESC;
