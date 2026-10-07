-- Create the project database (run while connected to the default "postgres" database)
CREATE DATABASE healthcare_dw;

-- Then connect to healthcare_dw and create the schemas
CREATE SCHEMA staging;       -- raw CSV data, loaded as-is
CREATE SCHEMA core;          -- cleaned, typed, with keys and constraints
CREATE SCHEMA data_quality;  -- data quality checks and issue log
CREATE SCHEMA analytics;     -- star schema for reporting
