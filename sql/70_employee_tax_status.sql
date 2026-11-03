-- ===========================================================================
-- 70_employee_tax_status.sql — mint the per-employee tax-status row the ZA
-- run preflight requires (blocker no_tax_status without it). Run ONCE PER
-- TENANT after 10_employees.sql.
--
-- Mapping from the interim employees record:
--   resident        <- taxcountrycode_f14 blank or ZA/ZAF => 1, else 0
--   dependent_count <- taxdependants_f08 (clamped 0..50, target CHECK)
--   disability      <- 0   CONFIRM: no interim source identified; ZA
--                          disability status must be captured manually
--   age_band        <- 'derived' (pack computes from date_of_birth)
--   effective_from  <- engagement date (same anchor as the contract row)
--
-- Runner variables: :legacy_company_schema :tenant_schema
--                   :cutover :system_user_id
-- ===========================================================================
\set ON_ERROR_STOP on
-- The legacy payroll number is READ FROM THE DATA, not supplied by the runner:
-- every interim employees row carries it in payroll_f04, and one schema holds
-- one payroll. A schema with no number, or with two, stops here rather than guess.
SELECT CASE WHEN count(DISTINCT payroll_f04) = 1 AND count(payroll_f04) = count(*)
            THEN min(payroll_f04)::text
            ELSE ('no single payroll number in ' || :'legacy_company_schema' || '.employees.payroll_f04: '
                  || COALESCE(string_agg(DISTINCT payroll_f04::text, ','), 'none'))::int::text
       END AS payroll_number
FROM :"legacy_company_schema".employees \gset
BEGIN;
SET search_path TO :"tenant_schema", public;

-- payroll-core 2026_10_28_100200 replaced hrm-core's employee_tax_status with
-- jurisdiction_tax_profiles: one profile per (employee, country), the ZA fields
-- as a JSON object of strings, exactly as that migration copied the old rows.
-- Written as plaintext: the readers decrypt only an encrypted value
-- (ColumnEncrypter::decryptIfEncrypted) and hrm-core's encryption backfill
-- job encrypts it at rest.
INSERT INTO jurisdiction_tax_profiles (
    employee_id, country_code, resident, tax_reference, fields,
    effective_from, recorded_at, created_by_user_id)
SELECT
    e.user_id,
    'ZA',
    CASE WHEN COALESCE(NULLIF(upper(s.taxcountrycode_f14), ''), 'ZAF') IN ('ZA','ZAF') THEN '1' ELSE '0' END,
    NULL,
    json_build_object(
        'dependent_count', LEAST(50, GREATEST(0, COALESCE(s.taxdependants_f08, 0)))::text,
        'disability', '0',
        'age_band', 'derived')::text,
    s.engagedate_d931::text,
    :'cutover', :system_user_id
FROM :"legacy_company_schema".employees s
-- via employee_code, as 10 builds it (EmployeeNo is unique only per payroll)
JOIN employees e ON e.employee_code = :'payroll_number' || '/' || s.employeeid_f01::text
WHERE NOT EXISTS (                                   -- idempotency
    SELECT 1 FROM jurisdiction_tax_profiles t WHERE t.employee_id = e.user_id AND t.country_code = 'ZA');

COMMIT;
\echo 'Done (employee tax status):' :tenant_schema '<-' :legacy_company_schema
