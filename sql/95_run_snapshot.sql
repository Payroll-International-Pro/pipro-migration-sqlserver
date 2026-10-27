-- ===========================================================================
-- 95_run_snapshot.sql — canonicalise ONE side of ONE kind of run, so the two
-- engines' output can be diffed by 96.
--
-- Runner variables:  :snap  :system (legacy|pipro)  :kind (live|validation)
--                    :tenant_schema  :period_id
--
-- HOW THIS DIFFERS FROM 91
-- ------------------------
-- 91 snapshots employee MASTER data, which is imported — so a difference there
-- is an import defect. This snapshots RUN OUTPUT, which is never imported: both
-- sides are GENERATED, by two different engines. A difference here is an engine
-- disagreement, which is a completely different kind of finding.
--
-- WHICH LEGACY TABLES
--   validation -> PW_T_Runf*  (what-if)    ~ pipro payslip_core_previews
--   live       -> PW_Runf*    (final run)  ~ pipro payslips_core + line tables
-- A live legacy run also writes run_history*, which we deliberately ignore:
-- PW_Runf* is the engine's own output, history is a copy of it.
--
-- NO PERIOD KEY ON THE LEGACY SIDE. PW_Runf* holds only the most recent run, so
-- whatever export-legacy-run.ps1 staged is what is compared. The pipro side is
-- selected by :period_id, and lining those two up is the operator's judgement.
--
-- TWO GRAINS, because the pipro side cannot always produce the finer one:
--   compare.run_value  per (employee, bank, ordinal) — the full comparison
--   compare.run_total  per (employee, metric)        — gross / paye / net
-- A what-if run in pipro stores only totals (payslip_core_previews), and even a
-- live run needs its labels mapped back to legacy ordinals. Totals always work,
-- so 96 falls back to them when the line grain is unavailable.
-- ===========================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE SCHEMA IF NOT EXISTS compare;

CREATE TABLE IF NOT EXISTS compare.run_snapshot (
    snap          TEXT PRIMARY KEY,
    system        TEXT NOT NULL CHECK (system IN ('legacy','pipro')),
    kind          TEXT NOT NULL CHECK (kind   IN ('live','validation')),
    tenant_schema TEXT,
    period_id     INTEGER,
    -- WHICH PERIOD THIS SIDE ACTUALLY RAN. The two systems are not guaranteed to
    -- be on the same period - legacy's PW_Runf* is simply "the last run", which
    -- may well be a month behind the pipro run being compared. Both labels are
    -- carried so the report can show them side by side, and a wall of
    -- differences can be read as "different periods" rather than "broken engine".
    period_label  TEXT,
    period_date   TEXT,
    taken_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Added after the table first shipped; CREATE TABLE IF NOT EXISTS above will not
-- add columns to an existing compare schema, so evolve it explicitly.
ALTER TABLE compare.run_snapshot ADD COLUMN IF NOT EXISTS period_label TEXT;
ALTER TABLE compare.run_snapshot ADD COLUMN IF NOT EXISTS period_date  TEXT;

CREATE TABLE IF NOT EXISTS compare.run_value (
    snap          TEXT    NOT NULL REFERENCES compare.run_snapshot(snap) ON DELETE CASCADE,
    employee_code TEXT    NOT NULL,
    bank          CHAR(1) NOT NULL CHECK (bank IN ('Q','V')),   -- no dates: PW_RunfDates does not exist
    ordinal_no    INTEGER NOT NULL,
    usage_no      INTEGER NOT NULL DEFAULT 1,
    value_num     NUMERIC,
    value_text    TEXT,
    origin        TEXT    NOT NULL,
    PRIMARY KEY (snap, employee_code, bank, ordinal_no, usage_no)
);

CREATE TABLE IF NOT EXISTS compare.run_total (
    snap          TEXT NOT NULL REFERENCES compare.run_snapshot(snap) ON DELETE CASCADE,
    employee_code TEXT NOT NULL,
    metric        TEXT NOT NULL,          -- gross | paye | net
    value_num     NUMERIC,
    origin        TEXT NOT NULL,
    PRIMARY KEY (snap, employee_code, metric)
);

-- Values the pipro side could not place on a legacy ordinal. Parked, never
-- guessed at — an unmapped line is reported, not silently dropped.
CREATE TABLE IF NOT EXISTS compare.run_value_unmapped (
    snap          TEXT NOT NULL REFERENCES compare.run_snapshot(snap) ON DELETE CASCADE,
    employee_code TEXT,
    label         TEXT,
    value_num     NUMERIC,
    origin        TEXT NOT NULL,
    reason        TEXT NOT NULL
);

DELETE FROM compare.run_snapshot WHERE snap = :'snap';

-- Legacy label from PW_RunH (live only; RunDate is a day-number on the same
-- 1799-12-31 epoch as every other legacy date). Pipro label from the period's
-- own dates plus when its latest run for that period finished.
INSERT INTO compare.run_snapshot (snap, system, kind, tenant_schema, period_id, period_label, period_date)
SELECT :'snap', :'system', :'kind', :'tenant_schema', NULLIF(:'period_id','')::int,
    CASE WHEN :'system' = 'legacy' THEN
        -- CurrentRun is a TAX-year position (March = 1), not a calendar month.
        -- It is shown as-is rather than translated: the run date beside it says
        -- unambiguously which month this is, and guessing is not this report's job.
        (SELECT CASE WHEN l.current_run IS NULL THEN 'globals row not readable'
                     ELSE 'run ' || l.current_run || ' (tax period '
                          || COALESCE(l.current_tax_period::text, '?') || ')' END
           FROM compare.legacy_run_label l WHERE l.kind = :'kind' LIMIT 1)
    ELSE
        (SELECT 'period ' || p.id || '  ' || p.period_start || ' .. ' || p.period_end || '  (' || p.status || ')'
           FROM :"tenant_schema".payroll_periods p WHERE p.id = NULLIF(:'period_id','')::int)
    END,
    CASE WHEN :'system' = 'legacy' THEN
        (SELECT CASE WHEN l.current_run_date IS NULL THEN NULL
                     ELSE (DATE '1799-12-31' + l.current_run_date)::text END
           FROM compare.legacy_run_label l WHERE l.kind = :'kind' LIMIT 1)
    ELSE
        (SELECT max(r.finished_at) FROM :"tenant_schema".payroll_runs r
          WHERE r.period_id = NULLIF(:'period_id','')::int)
    END;

-- ---------------------------------------------------------------------------
-- LEGACY. Ordinal-addressed already, so this is a straight carry. Amt is float
-- (same binary noise as PW_Amts) so it rounds to 4dp exactly as 93 does.
-- ---------------------------------------------------------------------------
INSERT INTO compare.run_value (snap, employee_code, bank, ordinal_no, usage_no, value_num, origin)
SELECT :'snap', btrim(a.payroll::text || '/' || a.empno::text), 'Q', a.ordinalno, a.usage_no, round(a.amt::numeric, 4), 'PW_RunfAmts'
FROM compare.legacy_runf_amts a
WHERE :'system' = 'legacy' AND a.kind = :'kind'
ON CONFLICT DO NOTHING;

INSERT INTO compare.run_value (snap, employee_code, bank, ordinal_no, usage_no, value_text, origin)
SELECT :'snap', btrim(i.payroll::text || '/' || i.empno::text), 'V', i.ordinalno, 1, i.ind, 'PW_RunfInds'
FROM compare.legacy_runf_inds i
WHERE :'system' = 'legacy' AND i.kind = :'kind'
ON CONFLICT DO NOTHING;

-- Legacy totals are ordinary Q values at whichever ordinals this payroll uses
-- for gross / PAYE / net. Those ordinals are NOT hardcoded: settings_taxcodes
-- names them per (payroll, currency) — gi_code, tax_code, net_code. On the
-- tenant checked they are 398 / 157 / 400, which is exactly why they must be
-- looked up rather than assumed.
INSERT INTO compare.run_total (snap, employee_code, metric, value_num, origin)
SELECT :'snap', v.employee_code, p.metric, v.value_num, 'PW_RunfAmts'
FROM compare.run_value v
JOIN (
    SELECT t.metric, t.ordinal_no
    FROM :"tenant_schema".settings_taxcodes s
    CROSS JOIN LATERAL (VALUES ('gross', s.gi_code), ('paye', s.tax_code), ('net', s.net_code))
        AS t(metric, ordinal_no)
    WHERE s.currency = 1                      -- CHOOSE: default-currency totals only
      -- a multi-payroll tenant holds one row per payroll: this export's payroll,
      -- read from the staged run (one legacy database = one payroll)
      AND s.payroll = (SELECT min(r.payroll) FROM compare.legacy_runf_amts r WHERE r.kind = :'kind')
) p ON p.ordinal_no = v.ordinal_no
WHERE v.snap = :'snap' AND v.bank = 'Q' AND :'system' = 'legacy'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- PIPRO. Totals always; lines only when a committed run has produced them.
-- Identity via compare.employee_map (90), never via 'emp-' || legacy EmpNo.
-- ---------------------------------------------------------------------------

-- Totals, validation kind: previews carry gross and net only (no PAYE column).
INSERT INTO compare.run_total (snap, employee_code, metric, value_num, origin)
SELECT :'snap', m.employee_code, t.metric, t.amount_minor::numeric / 100, 'payslip_core_previews'
FROM :"tenant_schema".payslip_core_previews p
CROSS JOIN LATERAL (VALUES ('gross', p.gross_minor), ('net', p.net_minor)) AS t(metric, amount_minor)
JOIN compare.employee_map m
  ON m.tenant_schema = :'tenant_schema' AND m.pipro_user_id = p.employee_id
WHERE :'system' = 'pipro' AND :'kind' = 'validation'
  AND p.period_id = NULLIF(:'period_id','')::int
  AND p.status <> 'excluded'
ON CONFLICT DO NOTHING;

-- PAYE for a validation run, from the ZA pack's preview child (written by the
-- engine-lane preview, payroll-za 2026_10_22_090000). Guarded: a tenant without
-- the table, or a preview from the per-employee lane, simply has no PAYE total.
SELECT set_config('mig95.snap', :'snap', true), set_config('mig95.tenant', :'tenant_schema', true),
       set_config('mig95.period', COALESCE(NULLIF(:'period_id', ''), '0'), true),
       set_config('mig95.system', :'system', true), set_config('mig95.kind', :'kind', true) \g /dev/null
DO $$
BEGIN
    IF current_setting('mig95.system') = 'pipro' AND current_setting('mig95.kind') = 'validation'
       AND to_regclass(current_setting('mig95.tenant') || '.payslip_statutory_za_previews') IS NOT NULL THEN
        EXECUTE format($q$
            INSERT INTO compare.run_total (snap, employee_code, metric, value_num, origin)
            SELECT $1, m.employee_code, 'paye', z.paye_minor::numeric / 100, 'payslip_statutory_za_previews'
              FROM %1$I.payslip_core_previews p
              JOIN %1$I.payslip_statutory_za_previews z ON z.period_id = p.period_id AND z.employee_id = p.employee_id
              JOIN compare.employee_map m ON m.tenant_schema = $2 AND m.pipro_user_id = p.employee_id
             WHERE p.period_id = $3 AND p.status <> 'excluded'
            ON CONFLICT DO NOTHING$q$, current_setting('mig95.tenant'))
        USING current_setting('mig95.snap'), current_setting('mig95.tenant'), current_setting('mig95.period')::int;
    END IF;
END $$;

-- Totals, live kind: committed payslips, with PAYE from the ZA statutory row.
INSERT INTO compare.run_total (snap, employee_code, metric, value_num, origin)
SELECT :'snap', m.employee_code, t.metric, t.amount_minor::numeric / 100, 'payslips_core'
FROM :"tenant_schema".payslips_core p
LEFT JOIN :"tenant_schema".payslip_statutory_za z ON z.payslip_id = p.id
CROSS JOIN LATERAL (VALUES ('gross', p.gross_minor), ('net', p.net_minor), ('paye', z.paye_minor)) AS t(metric, amount_minor)
JOIN compare.employee_map m
  ON m.tenant_schema = :'tenant_schema' AND m.pipro_user_id = p.employee_id
WHERE :'system' = 'pipro' AND :'kind' = 'live'
  AND p.period_id = NULLIF(:'period_id','')::int
  AND p.status <> 'excluded'
  AND t.amount_minor IS NOT NULL
ON CONFLICT DO NOTHING;

-- Lines, live kind. Earnings and deductions are label-addressed in pipro, so the
-- legacy ordinal is recovered through the amount catalogue by name — the same
-- bridge 91 uses. A label matching zero or several catalogue codes cannot be
-- placed, and is parked below rather than guessed.
INSERT INTO compare.run_value (snap, employee_code, bank, ordinal_no, usage_no, value_num, origin)
SELECT :'snap', m.employee_code, 'Q', c.ordinal_no, 1, x.amount_minor::numeric / 100, x.origin
FROM (
    SELECT p.employee_id, e.label, e.amount_minor, 'payslip_core_earnings' AS origin
      FROM :"tenant_schema".payslip_core_earnings e
      JOIN :"tenant_schema".payslips_core p ON p.id = e.payslip_id
     WHERE p.period_id = NULLIF(:'period_id','')::int
    UNION ALL
    SELECT p.employee_id, d.label, d.amount_minor, 'payslip_core_deductions'
      FROM :"tenant_schema".payslip_core_deductions d
      JOIN :"tenant_schema".payslips_core p ON p.id = d.payslip_id
     WHERE p.period_id = NULLIF(:'period_id','')::int
) x
JOIN :"tenant_schema".settings_employee_amounts c ON c.name = x.label
JOIN compare.employee_map m
  ON m.tenant_schema = :'tenant_schema' AND m.pipro_user_id = x.employee_id
WHERE :'system' = 'pipro' AND :'kind' = 'live'
  AND (SELECT count(*) FROM :"tenant_schema".settings_employee_amounts d2 WHERE d2.name = x.label) = 1
ON CONFLICT DO NOTHING;

INSERT INTO compare.run_value_unmapped (snap, employee_code, label, value_num, origin, reason)
SELECT :'snap', m.employee_code, x.label, x.amount_minor::numeric / 100, x.origin,
       'label matches ' || (SELECT count(*) FROM :"tenant_schema".settings_employee_amounts d2
                             WHERE d2.name = x.label)::text || ' catalogue ordinals'
FROM (
    SELECT p.employee_id, e.label, e.amount_minor, 'payslip_core_earnings' AS origin
      FROM :"tenant_schema".payslip_core_earnings e
      JOIN :"tenant_schema".payslips_core p ON p.id = e.payslip_id
     WHERE p.period_id = NULLIF(:'period_id','')::int
    UNION ALL
    SELECT p.employee_id, d.label, d.amount_minor, 'payslip_core_deductions'
      FROM :"tenant_schema".payslip_core_deductions d
      JOIN :"tenant_schema".payslips_core p ON p.id = d.payslip_id
     WHERE p.period_id = NULLIF(:'period_id','')::int
) x
JOIN compare.employee_map m
  ON m.tenant_schema = :'tenant_schema' AND m.pipro_user_id = x.employee_id
WHERE :'system' = 'pipro' AND :'kind' = 'live'
  AND (SELECT count(*) FROM :"tenant_schema".settings_employee_amounts d2 WHERE d2.name = x.label) <> 1;

COMMIT;

\echo ''
\echo '=== Run snapshot captured ================================================='
SELECT s.snap, s.system, s.kind, s.period_id,
       (SELECT count(*) FROM compare.run_value v WHERE v.snap = s.snap)          AS line_values,
       (SELECT count(*) FROM compare.run_total t WHERE t.snap = s.snap)          AS totals,
       (SELECT count(*) FROM compare.run_value_unmapped u WHERE u.snap = s.snap) AS unmapped
FROM compare.run_snapshot s WHERE s.snap = :'snap';

\echo ''
\echo '=== Rows per bank / origin ================================================'
SELECT bank, origin, count(*) AS rows, count(DISTINCT employee_code) AS employees
FROM compare.run_value WHERE snap = :'snap'
GROUP BY bank, origin ORDER BY bank, origin;
