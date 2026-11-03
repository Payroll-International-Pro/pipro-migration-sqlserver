-- ===========================================================================
-- 20_recurring.sql — import the amount-code CATALOGUE and route every
-- legacy employee_amounts value by CODETYPE. Run AFTER 10_employees.sql,
-- ONCE PER TENANT. Nothing is silently dropped.
--
--   settings_employee_amounts (catalogue, ALL codes incl. J) → settings_employee_amounts
--   codetype E → employee_amount_earnings
--   codetype D → employee_amount_deductions
--   codetype C → employee_amount_employer_cost     (cost-to-company; Q-addressed)
--   codetype B → employee_amount_balances          (LIVE working values: leave
--                                                   owed/taken, carry-forwards,
--                                                   basic rate per currency —
--                                                   RAW 4dp, no ×100)
--   codetype T → employee_amount_balances          (RAW — no assumptions about
--                                                   what a T slot holds)
--   codetype H → employee_amount_deprecated        (RAW HH:mm, NOT converted —
--                                                   conversion would mean
--                                                   retyping H→T; instead the
--                                                   user eyeballs deprecated
--                                                   and fixes per new-system
--                                                   rules)
--     Owner rule: the php system always populates T (decimal) and never
--     writes H — H phases out on deprecated.
--   codetype Y → migration.ytd_takeon              (mid-year YTD take-on staging
--                                                   → cumulative_ledger, see
--                                                   FOLLOW-UP below)
--   any OTHER recognised codetype (S,J,…)          → employee_amount_deprecated
--                                                    (dead codes; J = unsupported,
--                                                     calc treats as an amount or
--                                                     logs+skips)
--   codetype not found (no catalogue row)          → migration.amount_quarantine
--   employee never loaded (orphan)                 → migration.amount_quarantine
--
-- Values keep their OrdinalNo and stay Q-addressed — no reference rewrite (the
-- physical split is invisible above the loader). employee_amounts is keyed by
-- (EmployeeNo, OrdinalNo); the code name + codetype come from the catalogue,
-- joined on OrdinalNo.
--
-- Runner variables: :legacy_company_schema :tenant_schema :cutover :system_user_id
--
-- FOLLOW-UP: materialise migration.ytd_takeon → cumulative_ledger/payslip_fact
-- (needs the legacy-Y-code → aggregate-code map + per-period vs opening-balance
-- decision). B codes now land WHOLE in employee_amount_balances (2026-07-23);
-- any per-code refinement (leave→leave_balances, age→drop) is optional, later,
-- and data-driven off the catalogue.
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

CREATE SCHEMA IF NOT EXISTS migration;
CREATE TABLE IF NOT EXISTS migration.ytd_takeon (
    tenant TEXT NOT NULL, employee_id BIGINT NOT NULL, legacy_empno TEXT NOT NULL,
    code TEXT NOT NULL, amount_minor BIGINT NOT NULL, loaded_at TEXT NOT NULL);
-- The ordinal is the value's real address; the name alone is ambiguous once
-- two ordinals share one (e.g. a multi-payroll tenant where the same code sits
-- at different ordinals in different payrolls). NULL only on rows loaded before
-- this column existed.
ALTER TABLE migration.ytd_takeon ADD COLUMN IF NOT EXISTS ordinal_no INTEGER;
CREATE TABLE IF NOT EXISTS migration.amount_quarantine (
    tenant TEXT NOT NULL, legacy_empno TEXT NOT NULL, code TEXT, codetype TEXT,
    amount_minor BIGINT, reason TEXT NOT NULL, loaded_at TEXT NOT NULL);

-- ---- CATALOGUE: the unified amount-code definitions (every Q ordinal) --------
INSERT INTO settings_employee_amounts (
    ordinal_no, name, code_type, currency_code, code_limit_minor, tax_type,
    tax_inc_asn, consol_code, adjust_flag, manual_display, prorata, qmf_display)
SELECT
    s.ordinalno, s.description, upper(nullif(s.codetype,'')), s.currency_code,
    (COALESCE(s.codelimit,0)*100)::bigint, s.taxtype, s.taxincasn, s.consolcode,
    s.adjustflag,
    CASE WHEN s.manualdisplayind THEN 1 ELSE 0 END,
    CASE WHEN s.prorataind       THEN 1 ELSE 0 END,
    CASE WHEN s.qmfdisplayind    THEN 1 ELSE 0 END
FROM :"legacy_company_schema".settings_employee_amounts s
ON CONFLICT (ordinal_no) DO NOTHING;

-- ---- Stage the per-employee amounts (join catalogue on OrdinalNo) -----------
CREATE TEMP TABLE _amt ON COMMIT DROP AS
SELECT
    a.employeeno::text                AS legacy_empno,
    e.user_id                           AS employee_id,      -- pipro link; NULL if employee didn't load
    e.hired_at                          AS hired_at,
    a.ordinalno                       AS ordinal_no,       -- the Q-bank address (preserved)
    -- The TENANT's name for the ordinal (15_catalogue_merge may have chosen
    -- another payroll's spelling), so E/D labels match the catalogue. Routing
    -- below still uses this payroll's own codetype.
    COALESCE(tc.name, s.description)  AS name,             -- code name
    (a.amount_q * 100)::bigint        AS amount_minor,     -- ×100 major→minor
    a.amount_q                        AS amount_raw,       -- full 4dp (balances route)
    upper(nullif(s.codetype, ''))     AS codetype
FROM :"legacy_company_schema".employee_amounts a
LEFT JOIN :"legacy_company_schema".settings_employee_amounts s ON s.ordinalno = a.ordinalno
LEFT JOIN settings_employee_amounts tc ON tc.ordinal_no = a.ordinalno
-- Employee via employee_code, built exactly as 10_employees builds it. The
-- interim EmployeeNo is unique only within one legacy database, so a bare
-- EmployeeNo join would hand payroll 2's amounts to payroll 1's employees.
LEFT JOIN :"legacy_company_schema".employees le ON le.employeeno = a.employeeno
LEFT JOIN employees e ON e.employee_code = :'payroll_number' || '/' || le.employeeid_f01::text
WHERE a.amount_q <> 0;

-- E → earnings.  CHOOSE: label/payroll_code scheme (using catalogue name here).
INSERT INTO employee_amount_earnings (
    id, employee_id, label, amount_minor, taxable, uif_applicable,
    effective_from, recorded_at, created_by_user_id, ended_at, payroll_code)
SELECT
    COALESCE((SELECT max(id) FROM employee_amount_earnings),0) + row_number() OVER (ORDER BY employee_id, ordinal_no),
    employee_id, name, amount_minor, 1, 1,     -- CHOOSE: taxable / uif from catalogue
    hired_at, :'cutover', :system_user_id, NULL, name
FROM _amt WHERE employee_id IS NOT NULL AND codetype = 'E';

-- D → deductions.
INSERT INTO employee_amount_deductions (
    id, employee_id, label, amount_minor, reduces_taxable,
    effective_from, recorded_at, created_by_user_id, ended_at, payroll_code)
SELECT
    COALESCE((SELECT max(id) FROM employee_amount_deductions),0) + row_number() OVER (ORDER BY employee_id, ordinal_no),
    employee_id, name, amount_minor, 0,        -- CHOOSE: reduces_taxable from catalogue
    hired_at, :'cutover', :system_user_id, NULL, name
FROM _amt WHERE employee_id IS NOT NULL AND codetype = 'D';

-- C → employer cost (Q-addressed by ordinal).
INSERT INTO employee_amount_employer_cost (employee_id, ordinal_no, amount_minor)
SELECT employee_id, ordinal_no, amount_minor
FROM _amt WHERE employee_id IS NOT NULL AND codetype = 'C'
ON CONFLICT (employee_id, ordinal_no) DO NOTHING;

-- B + T → balances (LIVE working values; RAW 4dp — no ×100, no assumptions
-- about slot contents). Per-code refinement is a later, data-driven pass.
INSERT INTO employee_amount_balances (employee_id, ordinal_no, amount)
SELECT employee_id, ordinal_no, amount_raw
FROM _amt WHERE employee_id IS NOT NULL AND codetype IN ('B', 'T')
ON CONFLICT (employee_id, ordinal_no) DO NOTHING;

-- Y → YTD take-on staging (always mid-year; never dropped).
INSERT INTO migration.ytd_takeon (tenant, employee_id, legacy_empno, code, ordinal_no, amount_minor, loaded_at)
SELECT :'tenant_schema', employee_id, legacy_empno, name, ordinal_no, amount_minor, :'cutover'
FROM _amt WHERE employee_id IS NOT NULL AND codetype = 'Y';

-- Any OTHER recognised codetype (H,S,J,…) → deprecated, RAW. ×100 reverses
-- exactly for 2dp values: H HH:mm (12.45→1245), J DDMMYY ints, S scratch.
INSERT INTO employee_amount_deprecated (employee_id, ordinal_no, amount_minor, codetype)
SELECT employee_id, ordinal_no, amount_minor, codetype
FROM _amt WHERE employee_id IS NOT NULL AND codetype IS NOT NULL
  AND codetype NOT IN ('E','D','C','Y','B','T')
ON CONFLICT (employee_id, ordinal_no) DO NOTHING;

-- Salary display: employees.salary_current_minor = standing monthly gross
-- (the sum of routed E lines). The basiccode ordinal is a CALC INPUT (owner
-- 2026-08-01), never a display salary — see 10_employees Step 1 note.
-- amount_minor and salary_current_minor are TEXT since hrm-core / payroll-core
-- moved them to encrypted-at-rest columns; the rows this import just wrote are
-- still plaintext digits (the encryption backfill job encrypts them later).
UPDATE employees e SET salary_current_minor = COALESCE(
    (SELECT sum(x.amount_minor::bigint) FROM employee_amount_earnings x WHERE x.employee_id = e.user_id), 0)::text
WHERE e.id LIKE 'emp-%';

-- Codetype not found (no catalogue row for the ordinal) → quarantine (an error).
INSERT INTO migration.amount_quarantine (tenant, legacy_empno, code, codetype, amount_minor, reason, loaded_at)
SELECT :'tenant_schema', legacy_empno, name, codetype, amount_minor, 'codetype_not_found', :'cutover'
FROM _amt WHERE employee_id IS NOT NULL AND codetype IS NULL;

-- Orphans: amount rows whose employee never loaded → quarantine.
INSERT INTO migration.amount_quarantine (tenant, legacy_empno, code, codetype, amount_minor, reason, loaded_at)
SELECT :'tenant_schema', legacy_empno, name, codetype, amount_minor, 'employee_not_loaded', :'cutover'
FROM _amt WHERE employee_id IS NULL;

COMMIT;
\echo 'Done (catalogue + amounts routed by codetype):' :tenant_schema
