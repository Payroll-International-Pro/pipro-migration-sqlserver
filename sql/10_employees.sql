-- ===========================================================================
-- 10_employees.sql — the CORE employee record for one tenant, from one legacy
-- source schema. Run ONCE PER TENANT. Creates, in dependency order:
--   pipro_core_users → employees → employee_contracts
--                    → employment_payroll_allocations (puts them in the run worklist)
--                    → employee_status_history        (payable gate)
--
-- Runner variables: :legacy_company_schema :legacy_payroll_schema
--                   :tenant_schema :target_payroll_id
--                   :cutover :system_user_id     (see run-migration.ps1)
--
-- Target columns/types are VERBATIM from the live schema (real). Source column
-- names are from DataDictionary.java — CONFIRM against your desktop DB.
--
-- Marker legend:
--   CONFIRM = source is settled; just verify your data satisfies the target
--             rule (uniqueness / not-null / format), or that the stated
--             behaviour is acceptable. No column choice needed.
--   CHOOSE  = a genuine decision — pick the source column, transform, or rule.
--
-- Identity note (see README): pipro_core_users is a system USER/operator login;
-- pipro REQUIRES every employee to have one, so we MINT a login-user per
-- employee. Legacy integer EmployeeNo → the minted user_id (via _idmap); the
-- alpha EmployeeId_F01 → employee_code.
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

-- ---------------------------------------------------------------------------
-- Step 0: who keeps a SHARED real email address.
-- pipro_core_users.email is UNIQUE across the installation, but legacy let
-- several employees carry the same F40 address - the same person on two payrolls,
-- or two people sharing one. Owner rule (2026-10-19): among ALL employees of ALL
-- this tenant's payrolls holding an address, ONE keeps it - active before
-- terminated, then the most recently terminated, then the most recent
-- engagement (payroll number, then EmpNo, only to make it deterministic). Every
-- other copy gets the synthesised placeholder below, as does an address some
-- login outside this import already holds. Ranked across every migration_map
-- schema of the tenant, so each payroll's run picks the same winner.
-- ---------------------------------------------------------------------------
SELECT set_config('mig.tenant_schema', :'tenant_schema', true),
       set_config('mig.legacy_company_schema', :'legacy_company_schema', true),
       set_config('mig.payroll_number', :'payroll_number', true),
       set_config('mig.cutover', :'cutover', true) \g /dev/null

CREATE TEMP TABLE _email_holder (
    payroll_number INTEGER, empno TEXT, email_norm TEXT,
    active BOOLEAN, terminated_at DATE, hired_at DATE) ON COMMIT DROP;

DO $$
DECLARE m record;
BEGIN
  FOR m IN
    SELECT legacy_company_schema AS s
    FROM public.migration_map
    WHERE 'tenant_' || tenant_slug = current_setting('mig.tenant_schema')
    UNION   -- the schema being loaded, even if the map does not list it
    SELECT current_setting('mig.legacy_company_schema')
  LOOP
    -- Each payroll's number comes from its own rows (payroll_f04), like the
    -- one being loaded, so the ranking never depends on a typed-in value.
    EXECUTE format($q$
      INSERT INTO _email_holder
      SELECT e.payroll_f04, e.employeeid_f01::text, lower(btrim(e.emailaddress_f40)),
             d.term IS NULL OR d.term > $1::date, d.term, NULLIF(e.engagedate_d931::text, '')::date
      FROM %I.employees e
      CROSS JOIN LATERAL (SELECT NULLIF(e.dischargedate_d932::text, '')::date AS term) d
      WHERE btrim(COALESCE(e.emailaddress_f40, '')) <> ''$q$, m.s)
    USING left(current_setting('mig.cutover'), 10);
  END LOOP;
END $$;

CREATE TEMP TABLE _email_keep ON COMMIT DROP AS
SELECT DISTINCT ON (email_norm) email_norm, payroll_number, empno
FROM _email_holder
ORDER BY email_norm, active DESC, terminated_at DESC NULLS FIRST, hired_at DESC NULLS LAST, payroll_number, empno;

CREATE SCHEMA IF NOT EXISTS migration;
CREATE TABLE IF NOT EXISTS migration.email_replaced (
    tenant TEXT NOT NULL, employee_code TEXT NOT NULL, email TEXT NOT NULL,
    reason TEXT NOT NULL, kept_by TEXT, loaded_at TEXT NOT NULL,
    PRIMARY KEY (tenant, employee_code));

-- ---------------------------------------------------------------------------
-- Step 1: stage + normalise source rows (all conversions happen here).
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _src ON COMMIT DROP AS
SELECT
    e.employeeno::text                               AS legacy_empno,       -- join key → minted user_id
    -- QUALIFIED BY PAYROLL. employees.employee_code is UNIQUE across the whole
    -- tenant, but legacy only ever guaranteed EmpNo unique WITHIN a payroll
    -- database - global uniqueness was of the (Payroll, EmpNo) pair. A client
    -- with several payrolls converting into one tenant therefore collides, and
    -- step 3's ON CONFLICT DO NOTHING would SILENTLY SKIP the second payroll's
    -- employees. The prefix is the legacy payroll number, so codes read
    -- "3/57" = payroll 3, employee 57. It is injective because the payroll
    -- number cannot itself contain the separator, so it stays safe even where
    -- EmployeeId_F01 is alphanumeric.
    -- employee_code is user-facing and editable, so a client who wants something
    -- else can retype it afterwards.
    :'payroll_number' || '/' || e.employeeid_f01::text  AS employee_code,
    e.surname_f02                                    AS last_name,
    e.givennames_f21                                 AS first_name,
    e.identity_f12::text                             AS id_number,
    -- Passport: promoted to F45 in hop 1 from the slot PW_Parm_IRP5NonFinancial.
    -- PassportRefNo points at. The country of issue is PW_ImfC.PassportCountry
    -- (F46), ISO alpha-3 as SARS field 3075 wants it. Legacy only exports the
    -- passport when there is NO ID number, but both are carried here, as stored.
    NULLIF(btrim(e.passportnumber_f45), '')          AS passport_number,
    upper(NULLIF(btrim(e.passportcountry_f46), ''))  AS passport_country_code,
    e.birthdate_d930::text                           AS date_of_birth,      -- source sql format YYYY-MM-DD not null
    e.engagedate_d931::text                          AS hired_at,           -- source sql format YYYY-MM-DD not null
    NULLIF(e.dischargedate_d932::text, '')           AS terminated_at,      -- source sql format YYYY-MM-DD mostly null
    e.title_f28                                      AS title,
    e.occupation_f11                                 AS occupation,
    e.category_f13                                   AS category,
    'unspecified'                                      AS marital_status,
    1                                                  AS currency,
    upper(nullif(e.taxcountrycode_f14, ''))::char(3) AS nationality_country_code, -- there are two sets of country codes, one char(2) & one char(3)
    CASE upper(left(coalesce(e.gender_f22,''),1)) WHEN 'M' THEN 'male' WHEN 'F' THEN 'female' ELSE 'unspecified' END AS gender,
    -- Synthesised when F40 is blank, and QUALIFIED BY PAYROLL for the same reason
    -- employee_code is: pipro_core_users.email is UNIQUE across the whole
    -- installation, so two payrolls each holding an employee 57 would both
    -- synthesise '57@migrated.invalid'. Step 2 mints users with a plain INSERT and
    -- no conflict handling, so that collision does not skip a row - it FAILS the
    -- whole import. A dash rather than the code's slash, to stay a conventional
    -- local-part.
    -- A REAL address (F40) is used only by the one employee step 0 chose to
    -- keep it, and only while no other login holds it; every other copy falls
    -- back to the placeholder and is recorded in migration.email_replaced.
    CASE WHEN btrim(COALESCE(e.emailaddress_f40, '')) <> ''
              AND EXISTS (SELECT 1 FROM _email_keep k
                          WHERE k.email_norm = lower(btrim(e.emailaddress_f40))
                            AND k.payroll_number = :'payroll_number'::int
                            AND k.empno = e.employeeid_f01::text)
              AND NOT EXISTS (SELECT 1 FROM public.pipro_core_users u
                              WHERE lower(btrim(u.email)) = lower(btrim(e.emailaddress_f40)))
         THEN btrim(e.emailaddress_f40)
         ELSE :'payroll_number' || '-' || e.employeeid_f01::text || '@migrated.invalid'
    END                                              AS email,
    NULLIF(btrim(COALESCE(e.emailaddress_f40, '')), '') AS legacy_email
-- Basic rate (owner correction 2026-08-01, learned the hard way on the first
-- live comparison): the basiccode ordinal is a CALC INPUT (this client's is a
-- user-named annual "raise lever"), NOT period pay — mapping it to the
-- contract rate inflated every payslip ~13x. Period pay is the E-codes,
-- which 20_recurring imports as recurring earnings and which reproduce the
-- legacy gross EXACTLY (verified 169/170). So: contracts are created at
-- rate 0 (employment record only), pay flows from the imported lines, the
-- raise-lever value stays Q-addressed for the calcs, and
-- employees.salary_current_minor is set by 20_recurring from the routed
-- earnings (standing monthly gross).
FROM :"legacy_company_schema".employees e;

-- Record every real address that did not survive, and who kept it.
DELETE FROM migration.email_replaced
WHERE tenant = :'tenant_schema' AND employee_code LIKE :'payroll_number' || '/%';
INSERT INTO migration.email_replaced (tenant, employee_code, email, reason, kept_by, loaded_at)
SELECT :'tenant_schema', s.employee_code, s.legacy_email,
       CASE WHEN k.payroll_number || '/' || k.empno <> s.employee_code THEN 'shared_with_another_employee'
            ELSE 'already_held_by_another_login' END,
       k.payroll_number || '/' || k.empno, :'cutover'
FROM _src s
JOIN _email_keep k ON k.email_norm = lower(s.legacy_email)
WHERE s.legacy_email IS NOT NULL AND s.email <> s.legacy_email;

SELECT count(*) AS real_emails_replaced_with_placeholder
FROM migration.email_replaced
WHERE tenant = :'tenant_schema' AND employee_code LIKE :'payroll_number' || '/%';

-- ---------------------------------------------------------------------------
-- Step 2: pipro_core_users (public) — MINT one login-user per employee and
-- capture the generated BIGINT id (the key pipro's payroll tables use for the
-- employee). Columns are the REAL table: password_hash is NOT NULL — migrated
-- users get an unusable placeholder and cannot log in until a reset (irrelevant
-- to payroll; the engine never reads this table). is_active is an int flag.
-- NOTE: this is NOT the migration of your legacy OPERATOR accounts — that's a
-- separate concern; an operator who is also an employee may need de-duping later.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _idmap (legacy_empno TEXT PRIMARY KEY, user_id BIGINT) ON COMMIT DROP;

DO $$
DECLARE r record; new_uid bigint;
BEGIN
  FOR r IN SELECT * FROM _src LOOP
    INSERT INTO public.pipro_core_users
        (email, password_hash, first_name, last_name, is_active, created_at)
    VALUES
        (r.email, '!migrated-no-login', r.first_name, r.last_name, 1, current_timestamp::text)
    RETURNING id INTO new_uid;
    INSERT INTO _idmap (legacy_empno, user_id) VALUES (r.legacy_empno, new_uid);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- Step 3: employees. id is a TEXT PK — the app fills it with random hex; we use
-- deterministic 'emp-<payroll>-<EmpNo>' so it's idempotent AND preserves a trace
-- back to the interim EmployeeNo. QUALIFIED BY PAYROLL like employee_code: the
-- interim EmployeeNo is an auto-key unique only within one legacy database, so a
-- bare 'emp-<EmpNo>' failed a multi-payroll client's second payroll here on
-- employees_pkey ('emp-1' again) - ON CONFLICT (employee_code) does not cover the
-- primary key. Injective: EmpNo is digits only, so the LAST dash delimits it.
-- Nothing joins on this id - later scripts resolve employees through
-- employee_code. (This TEXT id is used only by hrm self-refs like manager_id;
-- the PAYROLL domain keys on user_id — see identity note.)
-- ---------------------------------------------------------------------------
-- NO email column here. hrm-core migration 2026_09_09_100000_employees_drop_email
-- removed it: an address belongs to the PERSON, so it lives on
-- pipro_core_users.email (UNIQUE) and employees.email was a second copy of the
-- same value, free to drift. The UNIQUE on the employment table also blocked the
-- re-engagement pattern legacy depends on - terminate the employment and open a
-- NEW one for the same person, each with its own YTD ledger and tax certificate -
-- because a re-engaged person keeps their address. The synthesised address above
-- is still used, but only for the user row minted in step 2.
INSERT INTO employees (
    id, user_id, employee_code, first_name, last_name, id_number,
    hired_at, terminated_at, salary_current_minor, currency, created_at,
    date_of_birth, gender, title, nationality_country_code, marital_status, preferred_name,
    occupation, category, passport_number, passport_country_code)
SELECT
    'emp-' || :'payroll_number' || '-' || s.legacy_empno, m.user_id, s.employee_code, s.first_name, s.last_name,
    s.id_number, s.hired_at, s.terminated_at, 0, s.currency,   -- salary display set by 20_recurring
    :'cutover', s.date_of_birth, s.gender, s.title, s.nationality_country_code,
    s.marital_status, NULL, s.occupation, s.category, s.passport_number, s.passport_country_code
FROM _src s JOIN _idmap m ON m.legacy_empno = s.legacy_empno
ON CONFLICT (employee_code) DO NOTHING;

-- Passports SARS would reject at year-end: no country of issue, or a country
-- that is not three letters. Loaded as stored; listed so they get fixed.
SELECT employee_code, passport_number, passport_country_code
FROM _src
WHERE passport_number IS NOT NULL
  AND (passport_country_code IS NULL OR passport_country_code !~ '^[A-Z]{3}$');

-- ---------------------------------------------------------------------------
-- Step 4: employee_contracts — bitemporal fan-out. One current monthly
-- contract; id is manual MAX+1 (BIGINT, no IDENTITY); rate 0 = employment record.
-- ---------------------------------------------------------------------------
INSERT INTO employee_contracts (
    id, employee_id, rate_type, rate_minor, currency, hours_per_week,
    org_unit_id, effective_from, recorded_at, created_by_user_id)
SELECT
    COALESCE((SELECT max(id) FROM employee_contracts), 0) + row_number() OVER (ORDER BY m.user_id),
    m.user_id, 'monthly', 0, s.currency,       -- rate 0: pay flows from imported lines
    40.00,              -- CHOOSE: hours_per_week
    NULL,               -- CHOOSE: org_unit_id (map dept → org_units(id))
    s.hired_at, :'cutover', :system_user_id
FROM _src s JOIN _idmap m ON m.legacy_empno = s.legacy_empno;
-- Rateless employees get a ZERO-RATE contract (hrm-core 2026_08_01_100000
-- relaxed the CHECK): employment exists, pay comes from configured amount
-- codes (bursary stipends etc.) — matches how legacy represented them.

-- ---------------------------------------------------------------------------
-- Step 5: employment_payroll_allocations — WITHOUT this the engine's worklist
-- never sees the employee. payroll_id = the tenant payroll from the map.
-- payroll-core 2026_10_28_100000 replaced employee_payroll_assignments (one
-- payroll per employee) with these allocations; a legacy employee belongs to
-- exactly one payroll, so the allocation is that payroll's whole share
-- (mode 'split', 10000 bp = 100%), active from the hire date.
-- ---------------------------------------------------------------------------
INSERT INTO employment_payroll_allocations (
    employee_id, payroll_id, status, mode, default_share_bp, share_basis,
    effective_from, recorded_at, created_by_user_id)
SELECT
    m.user_id, :target_payroll_id, 'active', 'split', 10000, 'default',
    s.hired_at, :'cutover', :system_user_id
FROM _src s JOIN _idmap m ON m.legacy_empno = s.legacy_empno;

-- ---------------------------------------------------------------------------
-- Step 6: employee_status_history — the engine treats ABSENT as active, so we
-- only strictly need a 'terminated' row for discharged staff. We write an
-- 'active' row at hire + a 'terminated' row at discharge.
-- status CHECK IN ('active','suspended','terminated').
-- ---------------------------------------------------------------------------
INSERT INTO employee_status_history (id, employee_id, status, effective_from, recorded_at, created_by_user_id)
SELECT
    COALESCE((SELECT max(id) FROM employee_status_history), 0) + row_number() OVER (ORDER BY m.user_id, k.ord),
    m.user_id, k.status, k.eff, :'cutover', :system_user_id
FROM _src s
JOIN _idmap m ON m.legacy_empno = s.legacy_empno
CROSS JOIN LATERAL (VALUES
    (1, 'active',     s.hired_at),
    (2, 'terminated', s.terminated_at)
) AS k(ord, status, eff)
WHERE k.eff IS NOT NULL;   -- the 'terminated' row only when a discharge date exists

-- ---------------------------------------------------------------------------
-- Step 7 (second pass): manager_id self-FK (references employees.id TEXT).
-- CHOOSE: needs the legacy reports-to EmpNo column; stubbed.
-- ---------------------------------------------------------------------------
-- UPDATE employees c SET manager_id = 'emp-' || :'payroll_number' || '-' || src.managerempno
-- FROM :"legacy_company_schema".employees src
-- WHERE c.id = 'emp-' || :'payroll_number' || '-' || src.employeeno::text;

COMMIT;
\echo 'Done (core):' :tenant_schema '<-' :legacy_company_schema
