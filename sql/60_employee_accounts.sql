-- ===========================================================================
-- 60_employee_accounts.sql — interim employee_accounts → employee_bank_details.
-- Run ONCE PER TENANT after 10_employees.sql. Requires the hrm-core widening
-- migration 2026_07_23_120000 (+ the pgsql CHECK drop) to be applied.
--
-- The interim table is keyed (EmployeeNo, OrdinalNo): multiple payment
-- destinations per employee with split-pay routing. ordinal_no carries the
-- slot number; the bitemporal columns are stamped with :cutover.
--
-- Runner variables: :legacy_company_schema :tenant_schema
--                   :cutover :system_user_id
--
-- CONFIRM: account_type receives the RAW legacy DestinAccountType code (the
--          CHECK was dropped for exactly this); mapping raw codes to
--          savings/current/transmission is a later data-driven cleanup.
-- CHOOSE:  blank account_currency defaults to 'ZAR' below.
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

INSERT INTO employee_bank_details (
    id, employee_id, ordinal_no,
    account_type, account_name, account_number, bank_sort_code, swift_code,
    currency, pay_mode, source_bank_account, split_pay_code,
    account_holder_status, sars_bank_account, iban,
    effective_from, recorded_at, created_by_user_id)
SELECT
    COALESCE((SELECT max(id) FROM employee_bank_details), 0)
        + row_number() OVER (ORDER BY e.user_id, s.ordinalno),
    e.user_id, s.ordinalno,
    COALESCE(NULLIF(s.accounttype_g1, ''), 'unknown'),      -- raw legacy code (CHECK dropped)
    COALESCE(s.accountname_g2, ''),                         -- target NOT NULL
    COALESCE(s.accountnumber_g3, ''),
    COALESCE(s.branchcode_g4, ''),
    NULL,                                                   -- swift_code: no interim source
    COALESCE(NULLIF(upper(s.accountcurrency_g10), ''), 'ZAR')::char(3),  -- CHOOSE: blank -> ZAR
    s.paymode_g0, s.sourcebankaccount_g5, s.splitpaycode_g6,
    s.accountholderstatus_g7,
    CASE WHEN s.sarsbankaccount_g8 THEN 1 ELSE 0 END,
    s.accountiban_g9,
    -- effective_from: the hire date, not the cutover. Accounts are looked up as of
    -- the payday, so stamping them with the conversion date hid every account
    -- from the first open period (paydays before the day of the conversion).
    COALESCE(NULLIF(e.hired_at, ''), :'cutover'), :'cutover', :system_user_id
FROM :"legacy_company_schema".employee_accounts s
-- via employee_code, as 10 builds it (EmployeeNo is unique only per payroll)
JOIN :"legacy_company_schema".employees le ON le.employeeno = s.employeeno
JOIN employees e ON e.employee_code = :'payroll_number' || '/' || le.employeeid_f01::text
WHERE NOT EXISTS (                                          -- idempotency: skip already-carried slots
    SELECT 1 FROM employee_bank_details b
     WHERE b.employee_id = e.user_id AND b.ordinal_no = s.ordinalno);

COMMIT;
\echo 'Done (employee accounts -> bank details):' :tenant_schema '<-' :legacy_company_schema
