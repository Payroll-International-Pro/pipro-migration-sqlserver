-- ===========================================================================
-- 65_payslip_line_settings.sql - the tenant's payslip line labels from its OWN
-- code catalogue. Once per tenant, after every payroll's import chain.
--
-- WHY: payroll-za seeds payslip_line_settings into every tenant from one client's
-- Pay020 code map (migration 2026_06_19_010200_seed_pay020_codes), so an imported
-- tenant's codes carried another client's names: Tau's 157 (Ded-period tax)
-- printed as "BASIC SALARY", 128 (a statistic) as "REIMB TVL".
--
-- WHAT: one earning / deduction row per code the tenant catalogue types E / D.
-- An imported program's payslip prints one line per such code (pipro-engine
-- LegacyPayslipLines), keyed by the code number, so this is where its label comes
-- from. Label:
--   * the legacy payslip DESCRIPTION, where the code is the only amount behind
--     exactly one earnings / deductions cell of the payroll's general payslip
--     layout (settings_payslip_descript / _amounts, matched on column and row)
--     and every payroll that prints it that way agrees on the wording;
--   * otherwise the catalogue name (e.g. "PAY-SALARY").
-- The layout is used for nothing else: legacy's grids can add several codes into
-- one row; pipro prints a line per code.
-- Statistical rows are left alone (they drive e.g. the taxable-income line),
-- except where one sits on a code that is now an earning / deduction.
--
-- Runner variables: :tenant_slug :tenant_schema
-- Writes: :tenant_schema.payslip_line_settings; migration.payslip_line_label
-- (this tenant's rows replaced) records where each label came from.
-- ===========================================================================
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL mig.tenant_slug = :'tenant_slug';

CREATE TABLE IF NOT EXISTS migration.payslip_line_label (
    tenant_slug TEXT NOT NULL, code INTEGER NOT NULL, category TEXT NOT NULL,
    label TEXT NOT NULL, source TEXT NOT NULL, layout_variants TEXT,
    PRIMARY KEY (tenant_slug, code));

-- ---- 1. Each payroll's one-code cells: (payroll, code, description)
CREATE TEMP TABLE layout_label (payroll INTEGER, code INTEGER, label TEXT) ON COMMIT DROP;
DO $$
DECLARE
    t TEXT := current_setting('mig.tenant_slug');
    m RECORD;
BEGIN
    FOR m IN SELECT legacy_company_schema AS s, legacy_payroll_number AS p
             FROM migration_map WHERE tenant_slug = t ORDER BY legacy_payroll_number
    LOOP
        IF to_regclass(format('%I.settings_payslip_descript', m.s)) IS NULL
           OR to_regclass(format('%I.settings_payslip_amounts', m.s)) IS NULL THEN
            CONTINUE;
        END IF;
        EXECUTE format($q$
            INSERT INTO layout_label (payroll, code, label)
            SELECT $1, cell.code, cell.label
              FROM (SELECT d.dcol, d.drow, btrim(d.description) AS label, max(a.aopn) AS code
                      FROM %1$I.settings_payslip_descript d
                      JOIN %1$I.settings_payslip_amounts a ON a.acol = d.dcol AND a.arow = d.drow
                     WHERE d.dcol IN (1, 2) AND btrim(COALESCE(d.description, '')) <> ''
                     GROUP BY d.dcol, d.drow, btrim(d.description)
                    HAVING count(*) = 1 AND max(upper(btrim(a.aopa))) = 'C' AND max(a.aopn) > 0) cell
             -- a code behind two cells of one payroll has no single description
             WHERE (SELECT count(*) FROM %1$I.settings_payslip_amounts a2
                     WHERE upper(btrim(a2.aopa)) = 'C' AND a2.aopn = cell.code AND a2.acol IN (1, 2)) = 1
            $q$, m.s) USING m.p;
    END LOOP;
END $$;

-- ---- 2. Decide each E / D code's label
DELETE FROM migration.payslip_line_label WHERE tenant_slug = :'tenant_slug';
INSERT INTO migration.payslip_line_label (tenant_slug, code, category, label, source, layout_variants)
SELECT :'tenant_slug', c.ordinal_no,
       CASE upper(c.code_type) WHEN 'E' THEN 'earning' ELSE 'deduction' END,
       CASE WHEN v.n = 1 THEN v.label ELSE btrim(c.name) END,
       CASE WHEN v.n = 1 THEN 'payslip layout'
            WHEN v.n > 1 THEN 'catalogue (layouts disagree)'
            ELSE 'catalogue' END,
       v.variants
  FROM :"tenant_schema".settings_employee_amounts c
  LEFT JOIN (SELECT code, count(DISTINCT upper(label)) AS n, min(label) AS label,
                    string_agg(DISTINCT payroll || ': ' || label, '; ') AS variants
               FROM layout_label GROUP BY code) v ON v.code = c.ordinal_no
 WHERE upper(c.code_type) IN ('E', 'D') AND btrim(COALESCE(c.name, '')) <> '';

-- ---- 3. Replace the seeded earning / deduction rows
DELETE FROM :"tenant_schema".payslip_line_settings
 WHERE category IN ('earning', 'deduction')
    OR payroll_code IN (SELECT code::text FROM migration.payslip_line_label WHERE tenant_slug = :'tenant_slug');
INSERT INTO :"tenant_schema".payslip_line_settings
       (payroll_code, category, sub_group, display_order, custom_label, visible, updated_at, updated_by_user_id)
SELECT code::text, category, NULL, code, label, 1, to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), NULL
  FROM migration.payslip_line_label WHERE tenant_slug = :'tenant_slug';

-- ---- 4. Report
\echo
\echo === Payslip line labels ======================================================
SELECT category, source, count(*) AS codes
  FROM migration.payslip_line_label WHERE tenant_slug = :'tenant_slug'
 GROUP BY 1, 2 ORDER BY 1, 2;
\echo --- codes whose payroll layouts disagree (catalogue name used; rename in payslip settings if wanted)
SELECT code, label, layout_variants
  FROM migration.payslip_line_label
 WHERE tenant_slug = :'tenant_slug' AND source = 'catalogue (layouts disagree)' ORDER BY code;

COMMIT;
