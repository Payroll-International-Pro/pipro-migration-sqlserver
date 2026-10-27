-- ===========================================================================
-- 96_run_diff.sql — diff two run snapshots, with the noise gates that keep a
-- structurally-different pair from printing thousands of useless rows.
--
-- Runner variables:  :a  :b   (run snapshot labels, a = legacy, b = pipro)
--                    :master_a  :master_b  (the 91 master snapshots, for gate 2)
--                    :tolerance (percent; default 10)
--
-- THE GATES, in the order they fire:
--
--   1. ONE SIDE EMPTY -> say so and stop.
--      3000 rows against 0 is not a diff, it is "the run has not been done".
--      Printing 3000 differences would bury that one fact.
--
--   2. MASTER DATA DIFFERS -> totals only, no line detail.
--      If the two systems disagree about what an employee IS, they will
--      disagree about every figure calculated from it. The line detail would
--      be thousands of consequences of a cause already reported by 92. Totals
--      still show, because the SIZE of the divergence is worth seeing.
--
--   3. ROW COUNTS DIFFER BY MORE THAN :tolerance -> summary only.
--      A structural mismatch (different code set, different employee set) is
--      not readable as a row list. Report the shape of it instead.
--
--   4. Otherwise -> full per-row detail, which is the case worth reading.
--
-- Totals are ALWAYS reported, at every gate. They are the one thing that is
-- meaningful whatever else is wrong.
-- ===========================================================================
\set ON_ERROR_STOP on

-- employee_code is "<payroll>/<EmpNo>", so the payroll a value belongs to is
-- recoverable from it. Returns NULL for a code that does not carry the prefix
-- (a user who renamed theirs), which makes the promoted-ordinal match simply not
-- apply - reporting the row as a difference rather than silently excluding it.
CREATE OR REPLACE FUNCTION compare.code_payroll(code text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $fn$
    SELECT CASE WHEN code ~ '^[0-9]+/' THEN split_part(code, '/', 1)::int END
$fn$;

-- ONE ROW PER (run snapshot pair, line), like 92's compare.value_diff. It used to
-- FULL JOIN every line against EVERY other run snapshot (ON ... b.snap <> a.snap),
-- so with more than two in compare, a line missing from B but present in some
-- third snapshot paired with that one instead and the snap_b filter dropped it:
-- a lost line vanished from the summary. snap_a / snap_b are always real labels
-- now, never '(absent)': filter on BOTH, or a query sums every pair.
CREATE OR REPLACE VIEW compare.run_value_diff AS
SELECT
    pr.snap_a,
    pr.snap_b,
    COALESCE(a.employee_code, b.employee_code) AS employee_code,
    COALESCE(a.bank, b.bank)                   AS bank,
    COALESCE(a.ordinal_no, b.ordinal_no)       AS ordinal_no,
    a.value_num                                AS a_num,
    b.value_num                                AS b_num,
    b.value_num - a.value_num                  AS delta,
    a.value_text                               AS a_text,
    b.value_text                               AS b_text,
    a.origin                                   AS a_origin,
    b.origin                                   AS b_origin,
    CASE
        WHEN a.snap IS NULL THEN 'only_in_b'
        WHEN b.snap IS NULL THEN 'only_in_a'
        WHEN COALESCE(a.bank, b.bank) = 'Q'
             AND a.value_num IS DISTINCT FROM b.value_num THEN 'value_differs'
        WHEN COALESCE(a.bank, b.bank) <> 'Q'
             AND btrim(COALESCE(a.value_text,'')) IS DISTINCT FROM btrim(COALESCE(b.value_text,'')) THEN 'value_differs'
        ELSE 'match'
    END AS verdict
FROM (SELECT sa.snap AS snap_a, sb.snap AS snap_b
        FROM compare.run_snapshot sa JOIN compare.run_snapshot sb ON sb.snap <> sa.snap) pr
-- Every key either side of THIS pair holds, then each side looked up on it: a
-- FULL JOIN scoped to the pair.
CROSS JOIN LATERAL (
    SELECT k.employee_code, k.bank, k.ordinal_no, k.usage_no
      FROM compare.run_value k
     WHERE k.snap IN (pr.snap_a, pr.snap_b)
     GROUP BY k.employee_code, k.bank, k.ordinal_no, k.usage_no) key
LEFT JOIN compare.run_value a
       ON  a.snap = pr.snap_a AND a.employee_code = key.employee_code
      AND  a.bank = key.bank  AND a.ordinal_no    = key.ordinal_no AND a.usage_no = key.usage_no
LEFT JOIN compare.run_value b
       ON  b.snap = pr.snap_b AND b.employee_code = key.employee_code
      AND  b.bank = key.bank  AND b.ordinal_no    = key.ordinal_no AND b.usage_no = key.usage_no;

-- ---------------------------------------------------------------------------
-- Decide which gate applies, once, so every section below agrees.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS _gate;
CREATE TEMP TABLE _gate AS
WITH counts AS (
    SELECT
        (SELECT count(*) FROM compare.run_value WHERE snap = :'a') AS a_lines,
        (SELECT count(*) FROM compare.run_value WHERE snap = :'b') AS b_lines,
        (SELECT count(*) FROM compare.run_total WHERE snap = :'a') AS a_totals,
        (SELECT count(*) FROM compare.run_total WHERE snap = :'b') AS b_totals,
        -- Counted by joining the two master snapshots directly, NOT through
        -- compare.value_diff. That view used to report a one-sided row as snap_b
        -- '(absent)', so filtering it by snap name dropped exactly the rows that
        -- matter most here - a value present in legacy and MISSING from pipro.
        -- (Both diff views are now scoped to the pair; this direct join stays.)
        -- Promoted ordinals are excluded: they are absent by design, not lost.
        (SELECT count(*)
           FROM (SELECT * FROM compare.employee_value WHERE snap = :'master_a') ma
           FULL JOIN (SELECT * FROM compare.employee_value WHERE snap = :'master_b') mb
             ON mb.employee_code = ma.employee_code
            AND mb.bank         = ma.bank
            AND mb.ordinal_no   = ma.ordinal_no
          WHERE NOT EXISTS (SELECT 1 FROM compare.promoted_ordinal p
                             WHERE p.payroll    = compare.code_payroll(COALESCE(ma.employee_code, mb.employee_code))
                               AND p.bank       = COALESCE(ma.bank, mb.bank)
                               AND p.ordinal_no = COALESCE(ma.ordinal_no, mb.ordinal_no))
            AND (ma.snap IS NULL OR mb.snap IS NULL
                 OR ma.value_num IS DISTINCT FROM mb.value_num
                 OR btrim(COALESCE(ma.value_text,'')) IS DISTINCT FROM btrim(COALESCE(mb.value_text,'')))
        ) AS master_diffs
)
SELECT *,
    CASE
        WHEN a_lines = 0 AND b_lines = 0 AND a_totals = 0 AND b_totals = 0 THEN 'nothing_to_compare'
        WHEN a_lines = 0 AND b_lines > 0 THEN 'legacy_run_missing'
        WHEN b_lines = 0 AND b_totals = 0 AND a_lines > 0 THEN 'pipro_run_missing'
        WHEN b_lines = 0 AND b_totals > 0 THEN 'totals_only_available'
        WHEN master_diffs > 0 THEN 'master_differs'
        WHEN a_lines = 0 OR b_lines = 0 THEN 'totals_only_available'
        WHEN abs(a_lines - b_lines)::numeric * 100 / greatest(a_lines, b_lines)
             > COALESCE(NULLIF(:'tolerance','')::numeric, 10) THEN 'shape_differs'
        ELSE 'full_detail'
    END AS gate
FROM counts;

\echo ''
\echo '=== 0. Which period did each side actually run? ==========================='
-- Legacy PW_Runf* is simply "the last run" and is NOT guaranteed to be the same
-- period as the pipro run. If these two rows disagree, expect a wall of
-- differences and read it as a period mismatch, not an engine fault.
SELECT system, kind, period_label, period_date, taken_at
FROM compare.run_snapshot WHERE snap IN (:'a', :'b')
ORDER BY system DESC;

\echo ''
\echo '=== 0a. Snapshot freshness ================================================'
-- The two snapshots are meant to be captured back-to-back by the report. A wide
-- gap means one of them FAILED and an older one survived: 95 wraps its
-- delete-and-insert in a transaction, so a failed capture rolls back and leaves
-- the previous snapshot in place - and everything below would then compare data
-- that no longer exists, with nothing but taken_at to give it away.
SELECT
    max(taken_at) - min(taken_at) AS captured_apart,
    CASE WHEN count(*) < 2 THEN 'ONE SIDE MISSING - a snapshot was never captured'
         WHEN max(taken_at) - min(taken_at) > interval '1 hour'
           THEN 'STALE - these were not captured together. Re-run the export and both 95 captures before reading anything below.'
         ELSE 'captured together' END AS verdict
FROM compare.run_snapshot WHERE snap IN (:'a', :'b');

\echo ''
\echo '=== 0b. Gate =============================================================='
SELECT a_lines, b_lines, a_totals, b_totals, master_diffs, gate,
       CASE gate
         WHEN 'nothing_to_compare'    THEN 'Neither side has run output. Nothing has been run yet.'
         WHEN 'legacy_run_missing'    THEN 'RUN NOT DONE ON LEGACY - the experimental side has output, legacy has none.'
         WHEN 'pipro_run_missing'     THEN 'RUN NOT DONE ON EXPERIMENTAL - totals only below, no comparison possible.'
         WHEN 'totals_only_available' THEN 'Experimental has totals but no per-line output (a what-if run stores only totals). Totals compared below.'
         WHEN 'master_differs'        THEN 'EMPLOYEE MASTER DATA DIFFERS - line detail suppressed, because every figure derives from it. Fix the import first (see 92), then re-read this.'
         WHEN 'shape_differs'         THEN 'Row counts differ by more than the tolerance - the two runs are structurally different, so a row list would not be readable. Summary only.'
         ELSE 'Comparable - full per-row detail below.'
       END AS meaning
FROM _gate;

\echo ''
\echo '=== 0c. Bank legend ======================================================='
\echo '    Q = amounts.  V = the alpha bank: legacy I (indicators) maps to V at the'
\echo '    same ordinal; legacy N (refnos) maps to V+100 but is NOT in run output,'
\echo '    so every V row here is a legacy I value. There is no date bank: legacy'
\echo '    has no PW_RunfDates.'

\echo ''
\echo '=== 1. Totals - always reported ==========================================='
SELECT t.metric,
       count(*)                                        AS employees,
       sum(la.value_num)                               AS legacy_total,
       sum(pb.value_num)                               AS pipro_total,
       sum(COALESCE(pb.value_num,0) - COALESCE(la.value_num,0)) AS delta,
       count(*) FILTER (WHERE la.value_num IS DISTINCT FROM pb.value_num) AS employees_differing
FROM (SELECT DISTINCT metric FROM compare.run_total WHERE snap IN (:'a', :'b')) t
LEFT JOIN compare.run_total la ON la.snap = :'a' AND la.metric = t.metric
LEFT JOIN compare.run_total pb ON pb.snap = :'b' AND pb.metric = t.metric
                              AND pb.employee_code = la.employee_code
GROUP BY t.metric ORDER BY t.metric;

\echo ''
\echo '=== 2a. Metrics missing from one side entirely ============================'
-- Reported ONCE PER METRIC, not once per employee. A metric the other side does
-- not produce at all is one finding, not 150 - and listing it per employee buries
-- the metrics that genuinely disagree. pipro previews carry gross and net only,
-- so PAYE lands here until a run is COMMITTED and payslip_statutory_za exists.
SELECT metric,
       count(*) FILTER (WHERE side = 'legacy only') AS legacy_only_employees,
       count(*) FILTER (WHERE side = 'pipro only')  AS pipro_only_employees,
       sum(value_num) FILTER (WHERE side = 'legacy only') AS legacy_unmatched_total,
       sum(value_num) FILTER (WHERE side = 'pipro only')  AS pipro_unmatched_total
FROM (
    SELECT la.metric, la.value_num, 'legacy only' AS side
      FROM compare.run_total la
      LEFT JOIN compare.run_total pb ON pb.snap = :'b' AND pb.employee_code = la.employee_code
                                    AND pb.metric = la.metric
     WHERE la.snap = :'a' AND pb.snap IS NULL
    UNION ALL
    SELECT pb.metric, pb.value_num, 'pipro only'
      FROM compare.run_total pb
      LEFT JOIN compare.run_total la ON la.snap = :'a' AND la.employee_code = pb.employee_code
                                    AND la.metric = pb.metric
     WHERE pb.snap = :'b' AND la.snap IS NULL
) x
GROUP BY metric ORDER BY metric;

\echo ''
\echo '=== 2b. EVERY employee whose totals differ, by metric ====================='
-- No cap. Grouped by metric first so one noisy metric cannot crowd out another,
-- then worst delta first within each. Only metrics present on BOTH sides appear
-- here; a wholly absent metric is section 2a's business.
SELECT la.metric, la.employee_code, la.value_num AS legacy, pb.value_num AS pipro,
       pb.value_num - la.value_num AS delta
FROM compare.run_total la
JOIN compare.run_total pb ON pb.snap = :'b' AND pb.employee_code = la.employee_code
                         AND pb.metric = la.metric
WHERE la.snap = :'a' AND la.value_num IS DISTINCT FROM pb.value_num
ORDER BY la.metric, abs(pb.value_num - la.value_num) DESC, la.employee_code;

\echo ''
\echo '=== 3. Line summary by bank ==============================================='
SELECT bank, verdict, count(*) AS rows, count(DISTINCT employee_code) AS employees
FROM compare.run_value_diff
WHERE snap_a = :'a' AND snap_b = :'b'
  AND (SELECT gate FROM _gate) NOT IN ('nothing_to_compare','pipro_run_missing','legacy_run_missing')
GROUP BY bank, verdict ORDER BY bank, verdict;

\echo ''
\echo '=== 4. Differing ordinals (suppressed unless the gate allows detail) ======='
SELECT bank, ordinal_no, COALESCE(a_origin, b_origin) AS origin,
       count(*) AS rows,
       sum(abs(COALESCE(delta,0))) AS total_abs_delta,
       max(abs(COALESCE(delta,0))) AS worst_delta
FROM compare.run_value_diff
WHERE verdict <> 'match' AND snap_a = :'a' AND snap_b = :'b'
  AND (SELECT gate FROM _gate) IN ('full_detail','shape_differs')
GROUP BY bank, ordinal_no, COALESCE(a_origin, b_origin)
ORDER BY rows DESC, total_abs_delta DESC;

\echo ''
\echo '=== 5. Differing rows (full detail only) =================================='
SELECT employee_code, bank, ordinal_no, a_num AS legacy, b_num AS pipro, delta, a_text, b_text, verdict
FROM compare.run_value_diff
WHERE verdict <> 'match' AND snap_a = :'a' AND snap_b = :'b'
  AND (SELECT gate FROM _gate) = 'full_detail'
-- No cap. Payroll differences get checked line by line, so a truncated list is
-- worse than a long one. Ordered by ordinal then employee so one code's rows sit
-- together; redirect the report to a file if the console is unwieldy.
ORDER BY bank, ordinal_no, employee_code;

\echo ''
\echo '=== 6. Experimental lines that could not be placed on a legacy ordinal ===='
SELECT label, origin, reason, count(*) AS rows
FROM compare.run_value_unmapped WHERE snap = :'b'
GROUP BY label, origin, reason ORDER BY count(*) DESC;
