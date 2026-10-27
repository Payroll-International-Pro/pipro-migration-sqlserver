-- ===========================================================================
-- 93_legacy_snapshot.sql — turn the staged SQL Server extract (loaded by
-- export-legacy.ps1 into compare.legacy_*) into a canonical snapshot, so it
-- diffs against interim/pipro snapshots with 92 like any other.
--
-- Runner variables:  :snap  :phase
--
-- LEGACY TYPE CONVERSIONS (verified against the live DB 2026-09-17)
-- -----------------------------------------------------------------
--   PW_Amts.Amt       float      -> NUMERIC, round(,4). Amt is BINARY FLOAT and
--                                carries representation noise: 16195.62 is
--                                stored as 16195.619999999999. Rounding to 4
--                                kills the noise while preserving genuine 4dp
--                                values (B-bank rates / day counts). NOTE the
--                                interim rounded to 2dp — if a client ever has
--                                a real 3-4dp value, this diff will report it,
--                                correctly, as interim precision loss.
--   PW_Dates.DateValue int       -> DATE '1799-12-31' + n. Day-number epoch,
--                                confirmed on three samples (69183=1989-06-01,
--                                70462=1992-12-01, 72361=1998-02-12).
--   PW_Inds.Ind        varchar(1)  -> bank V at the ordinal as-is.
--   PW_RefNos.RefNo    varchar(25) -> bank V at ordinal + 100, BUT see the
--                                RefNoCode indirection below — for some ordinals
--                                RefNo is blank and the value lives in a code.
-- ===========================================================================
\set ON_ERROR_STOP on
BEGIN;

-- ---------------------------------------------------------------------------
-- PROMOTED ORDINALS - legacy slots that became first-class employee columns
-- during hop 1, so they are ABSENT from the alpha bank downstream BY DESIGN.
-- Without this table the diff reports those rows as phantom losses.
--
-- DERIVED, NEVER HARDCODED. Which slots are promoted is CLIENT CONFIGURATION,
-- read by SQLImport.getMoveOrdinals from pw_parm_payrollUser (EmpCategoryInd,
-- IdRef, SexInd) plus a passport lookup - and it is PER PAYROLL, so a client
-- with three payrolls can have three different sets. Hardcoding misreports in
-- BOTH directions at once: the real promotions surface as `only_in_a` losses,
-- while the wrongly-listed ordinals are silently excluded, hiding real ones.
--
-- Indicator pointers address bank V directly; REFNO pointers address V+100, the
-- same offset DataDictionary applies when merging pw_inds and pw_refnos.
-- A pointer of 0 means the client did not configure that promotion.
--
-- Rebuilt from scratch each run, because it describes whichever client was
-- last staged.
-- ---------------------------------------------------------------------------
-- employee_code is "<payroll>/<EmpNo>", so the payroll a value belongs to is
-- recoverable from it. Returns NULL for a code that does not carry the prefix
-- (a user who renamed theirs), which makes the promoted-ordinal match simply not
-- apply - reporting the row as a difference rather than silently excluding it.
CREATE OR REPLACE FUNCTION compare.code_payroll(code text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $fn$
    SELECT CASE WHEN code ~ '^[0-9]+/' THEN split_part(code, '/', 1)::int END
$fn$;

-- ONE SET PER PAYROLL, KEPT. Each export replaces only the payroll(s) it staged,
-- so a multi-payroll tenant holds every payroll's promoted slots at once and the
-- run report's master gate (96) can read any of them. (It used to be dropped and
-- rebuilt from the last export alone, which also dropped the diff views that
-- depend on it.)
CREATE TABLE IF NOT EXISTS compare.promoted_ordinal (
    payroll        INTEGER NOT NULL,
    bank           CHAR(1) NOT NULL,
    ordinal_no     INTEGER NOT NULL,
    legacy_name    TEXT,
    target_column  TEXT NOT NULL,
    -- The system-neutral name compare.employee_promoted files the value under.
    field          TEXT,
    rows_in_legacy INTEGER,
    PRIMARY KEY (payroll, bank, ordinal_no)
);
-- CREATE TABLE IF NOT EXISTS never adds a column to an existing table.
ALTER TABLE compare.promoted_ordinal ADD COLUMN IF NOT EXISTS field TEXT;
DELETE FROM compare.promoted_ordinal
 WHERE payroll IN (SELECT payroll FROM compare.legacy_promoted);

INSERT INTO compare.promoted_ordinal (payroll, bank, ordinal_no, legacy_name, target_column, field)
SELECT p.payroll, 'V', p.sex_ind,
       'indicator ' || p.sex_ind || ' (SexInd)', 'employees.gender_f22', 'gender'
  FROM compare.legacy_promoted p WHERE p.sex_ind > 0
UNION ALL
SELECT p.payroll, 'V', p.empcategory_ind,
       'indicator ' || p.empcategory_ind || ' (EmpCategoryInd)', 'employees.category_f13', 'category'
  FROM compare.legacy_promoted p WHERE p.empcategory_ind > 0
UNION ALL
SELECT p.payroll, 'V', p.id_ref + 100,
       'refno ' || p.id_ref || ' (IdRef)', 'employees.identity_f12', 'id_number'
  FROM compare.legacy_promoted p WHERE p.id_ref > 0
UNION ALL
SELECT p.payroll, 'V', p.passport_refno + 100,
       'refno ' || p.passport_refno || ' (PassportRefNo)', 'employees.passportnumber_f45', 'passport_number'
  FROM compare.legacy_promoted p WHERE p.passport_refno > 0
ON CONFLICT (payroll, bank, ordinal_no) DO NOTHING;

-- How many legacy rows each promoted slot actually held. Informational, and the
-- figure that should reappear as the alpha-bank shortfall in section 2.
UPDATE compare.promoted_ordinal o SET rows_in_legacy = (
    CASE WHEN o.ordinal_no >= 100
         THEN (SELECT count(*) FROM compare.legacy_refnos r
                JOIN compare.legacy_imf m ON m.empno = r.empno
               WHERE r.ordinalno = o.ordinal_no - 100 AND m.payroll = o.payroll)
         ELSE (SELECT count(*) FROM compare.legacy_inds i
                JOIN compare.legacy_imf m ON m.empno = i.empno
               WHERE i.ordinalno = o.ordinal_no AND m.payroll = o.payroll)
    END);

DELETE FROM compare.snapshot WHERE snap = :'snap';
INSERT INTO compare.snapshot (snap, system, phase, source_schema)
VALUES (:'snap', 'legacy', :'phase', 'sqlserver:pipro');

-- Q — amounts. float -> numeric(,4).
INSERT INTO compare.employee_value (snap, employee_code, bank, ordinal_no, value_num, origin)
SELECT :'snap', btrim(m.payroll::text || '/' || m.empno::text), 'Q', a.ordinalno, round(a.amt::numeric, 4), 'PW_Amts'
FROM compare.legacy_amts a
JOIN compare.legacy_imf  m ON m.empno = a.empno
ON CONFLICT DO NOTHING;

-- V — indicators at the ordinal as-is.
INSERT INTO compare.employee_value (snap, employee_code, bank, ordinal_no, value_text, origin)
SELECT :'snap', btrim(m.payroll::text || '/' || m.empno::text), 'V', i.ordinalno, i.ind, 'PW_Inds'
FROM compare.legacy_inds i
JOIN compare.legacy_imf  m ON m.empno = i.empno
ON CONFLICT DO NOTHING;

-- V — references at ordinal + 100 (the DataDictionary offset), resolving the
-- RefNoCode indirection (owner 2026-09-17, verified against the live DB):
--   PW_Parm_RefNoNames.RefNoDescInd = 'N'  -> the employee's value is
--       PW_Descf.Description, keyed (Payroll, RefNo = the parm OrdinalNo,
--       DescCode = the employee's RefNoCode).
--   anything else (space, or 'Y')          -> the value is PW_RefNos.RefNo.
-- Live data: 29 ordinals blank, 2 are 'N' (6 OFFICE, 7 SITE), 1 is 'Y'
-- (22 SAP CATEGORY).
--
-- 'Y' (owner 2026-09-17) behaves EXACTLY like space at read time: RefNo is the
-- value. The difference is only in how RefNo got there — it was DEFAULTED from
-- PW_Descf.Description when first captured, and the user may have edited it
-- since. So on a Y ordinal the code is a provenance breadcrumb, not the value,
-- and text that no longer matches its code is a legitimate edit rather than
-- drift. CONSEQUENCE: once the N resolution happens at import, RefNoCode itself
-- needs no home downstream — for N it has been resolved into the value, and for
-- Y it only records what the default used to be.
INSERT INTO compare.employee_value (snap, employee_code, bank, ordinal_no, value_text, origin)
SELECT :'snap', btrim(m.payroll::text || '/' || m.empno::text), 'V', r.ordinalno + 100,
       CASE WHEN p.refnodescind = 'N' THEN d.description ELSE r.refno END,
       CASE WHEN p.refnodescind = 'N' THEN 'PW_Descf'    ELSE 'PW_RefNos' END
FROM compare.legacy_refnos r
JOIN compare.legacy_imf    m ON m.empno = r.empno
LEFT JOIN compare.legacy_parm_refnos p ON p.ordinalno = r.ordinalno
LEFT JOIN compare.legacy_descf       d ON d.payroll   = p.payroll
                                      AND d.refno     = p.ordinalno
                                      AND d.desccode  = r.refnocode
ON CONFLICT DO NOTHING;

-- D — dates. day-number -> DATE, rendered ISO to match the downstream TEXT.
INSERT INTO compare.employee_value (snap, employee_code, bank, ordinal_no, value_text, origin)
SELECT :'snap', btrim(m.payroll::text || '/' || m.empno::text), 'D', d.ordinalno,
       (DATE '1799-12-31' + d.datevalue)::text, 'PW_Dates'
FROM compare.legacy_dates d
JOIN compare.legacy_imf   m ON m.empno = d.empno
ON CONFLICT DO NOTHING;

-- PROMOTED VALUES, filed by field name so 92 can check them against the employee
-- COLUMNS they became downstream - excluding the slots from the value diff (the
-- 'promoted' verdict) is only safe if something proves the values arrived. Same
-- DDL as 91, which may not have run yet on this database.
-- Plus the passport's country of issue, which legacy keeps on PW_ImfC rather
-- than in a slot.
CREATE TABLE IF NOT EXISTS compare.employee_promoted (
    snap          TEXT NOT NULL REFERENCES compare.snapshot(snap) ON DELETE CASCADE,
    employee_code TEXT NOT NULL,
    field         TEXT NOT NULL CHECK (field IN ('category','gender','id_number','passport_number','passport_country')),
    value_text    TEXT,               -- as stored; 92 normalises when comparing
    origin        TEXT NOT NULL,
    PRIMARY KEY (snap, employee_code, field)
);

INSERT INTO compare.employee_promoted (snap, employee_code, field, value_text, origin)
SELECT :'snap', v.employee_code, p.field, v.value_text, v.origin
FROM compare.employee_value v
JOIN compare.promoted_ordinal p
  ON p.bank = v.bank AND p.ordinal_no = v.ordinal_no
 AND p.payroll = compare.code_payroll(v.employee_code)
WHERE v.snap = :'snap'
UNION ALL
SELECT :'snap', btrim(m.payroll::text || '/' || m.empno::text), 'passport_country', m.passport_country, 'PW_ImfC'
FROM compare.legacy_imf m
WHERE btrim(COALESCE(m.passport_country, '')) <> ''
ON CONFLICT DO NOTHING;

-- Fill the legacy key on the map now that we have PW_IMF. The spine is the
-- payroll-qualified code; legacy_empno holds the BARE EmpNo, and exists to prove
-- the derivation rather than to be joined through.
UPDATE compare.employee_map m
   SET legacy_empno = l.empno::text
  FROM compare.legacy_imf l
 WHERE btrim(m.employee_code) = btrim(l.payroll::text || '/' || l.empno::text);

COMMIT;

\echo ''
\echo '=== 1. Legacy snapshot captured ==========================================='
SELECT bank, origin, count(*) AS rows, count(DISTINCT employee_code) AS employees
FROM compare.employee_value WHERE snap = :'snap'
GROUP BY bank, origin ORDER BY bank, origin;

\echo ''
\echo '=== 2. Alpha-bank reconciliation (promotions accounted for) ==============='
SELECT
    (SELECT count(*) FROM compare.employee_value WHERE snap = :'snap' AND bank='V') AS legacy_alpha_rows,
    (SELECT count(*) FROM compare.employee_value v JOIN compare.promoted_ordinal p
       ON p.bank=v.bank AND p.ordinal_no=v.ordinal_no
      AND p.payroll = compare.code_payroll(v.employee_code) WHERE v.snap = :'snap') AS promoted_rows,
    (SELECT count(*) FROM compare.employee_value v WHERE v.snap = :'snap' AND v.bank='V'
        AND NOT EXISTS (SELECT 1 FROM compare.promoted_ordinal p
                         WHERE p.bank=v.bank AND p.ordinal_no=v.ordinal_no
                           AND p.payroll = compare.code_payroll(v.employee_code)))  AS expected_downstream;

\echo ''
\echo '=== 3. RefNoCode indirection - how each ordinal resolves ==================='
SELECT p.ordinalno, p.refnoname, '[' || p.refnodescind || ']' AS desc_ind,
       CASE WHEN p.refnodescind = 'N' THEN 'PW_Descf.Description' ELSE 'PW_RefNos.RefNo' END AS value_source,
       count(r.empno)                                                      AS employee_rows,
       count(*) FILTER (WHERE btrim(COALESCE(r.refnocode,'')) <> '')       AS rows_with_code
FROM compare.legacy_parm_refnos p
LEFT JOIN compare.legacy_refnos r ON r.ordinalno = p.ordinalno
GROUP BY p.ordinalno, p.refnoname, p.refnodescind
HAVING count(*) FILTER (WHERE btrim(COALESCE(r.refnocode,'')) <> '') > 0
    OR p.refnodescind = 'N'
ORDER BY p.ordinalno;

\echo ''
\echo '=== 4. N-ordinal codes that do NOT resolve to a description =============== '
-- An unresolved code means the employee value is LOST, not merely reformatted.
SELECT r.ordinalno, r.refnocode, count(*) AS employee_rows
FROM compare.legacy_refnos r
JOIN compare.legacy_parm_refnos p ON p.ordinalno = r.ordinalno AND p.refnodescind = 'N'
LEFT JOIN compare.legacy_descf d ON d.payroll = p.payroll AND d.refno = p.ordinalno
                                AND d.desccode = r.refnocode
WHERE d.description IS NULL
GROUP BY r.ordinalno, r.refnocode
ORDER BY r.ordinalno, r.refnocode;

\echo ''
\echo '=== 5. Y-ordinals: values edited away from their defaulted description ===='
-- INFORMATIONAL, NOT A DEFECT. On a 'Y' ordinal RefNo is seeded from the
-- description and is then freely editable, so a value that no longer matches its
-- code is a deliberate user edit. Listed because it is the only visible trace of
-- which values were hand-altered, and because it would otherwise look alarming
-- in section 3's counts. Nothing here needs fixing.
SELECT r.ordinalno, r.empno, r.refno AS stored_text, r.refnocode, d.description AS code_resolves_to
FROM compare.legacy_refnos r
JOIN compare.legacy_parm_refnos p ON p.ordinalno = r.ordinalno AND COALESCE(p.refnodescind,'') <> 'N'
JOIN compare.legacy_descf d ON d.payroll = p.payroll AND d.refno = p.ordinalno
                           AND d.desccode = r.refnocode
WHERE btrim(r.refno) IS DISTINCT FROM btrim(d.description)
ORDER BY r.ordinalno, r.empno;

\echo ''
\echo '=== 6. Map: legacy key resolved ==========================================='
SELECT count(*) FILTER (WHERE legacy_empno IS NOT NULL) AS resolved,
       count(*) FILTER (WHERE legacy_empno IS NULL)     AS unresolved,
       count(*) AS total
FROM compare.employee_map;
