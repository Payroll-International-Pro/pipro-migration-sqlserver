-- ===========================================================================
-- 58_promote_calc_program.sql - make a payroll's STAGED legacy calc program
-- (57: program_key 'legacy:payroll-<id>') the program its runs use
-- ('payroll-<id>'), or undo that. NOT part of the import chain: promote once the
-- staged program has been traced against legacy for that payroll
-- (POST /v1/run with stagedLegacyProgram + traceEmployee), via
-- promote-calc-program.ps1.
--
-- The engine resolves 'payroll-<id>', else 'default'. A program whose lines carry
-- calc_time runs the legacy pay cycle (LegacyCalcList), so the rename alone moves
-- every later run of the payroll - previews included - onto the client's program.
--
-- promote: any program already at 'payroll-<id>' (a pipro-authored one) is set
--          aside as 'retired:payroll-<id>:<UTC timestamp>', never deleted; then
--          the staged rows take the live key. Refuses when nothing is staged.
-- demote:  the live legacy program goes back to the staged key, and the most
--          recently retired program (if any) returns to 'payroll-<id>'. Refuses
--          when the live program is not a legacy one, or something is staged
--          already (two staged copies would be ambiguous).
--
-- Runner variables: :tenant_schema :target_payroll_id :action (promote|demote)
-- ===========================================================================
\set ON_ERROR_STOP on
BEGIN;
SET search_path TO :"tenant_schema", public;
SET LOCAL mig.payroll = :'target_payroll_id';
SET LOCAL mig.action  = :'action';

DO $$
DECLARE
    p        TEXT := current_setting('mig.payroll');
    live     TEXT := 'payroll-' || current_setting('mig.payroll');
    staged   TEXT := 'legacy:payroll-' || current_setting('mig.payroll');
    stamp    TEXT := to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDD"T"HH24MISS"Z"');
    n_staged INT;
    n_live   INT;
    n_legacy INT;
    retired  TEXT;
BEGIN
    SELECT count(*) INTO n_staged FROM calc_program WHERE program_key = staged;
    SELECT count(*), count(calc_time) INTO n_live, n_legacy FROM calc_program WHERE program_key = live;

    IF current_setting('mig.action') = 'promote' THEN
        IF n_staged = 0 THEN
            RAISE EXCEPTION 'payroll %: nothing staged under %', p, staged;
        END IF;
        IF n_live > 0 THEN
            UPDATE calc_program SET program_key = 'retired:' || live || ':' || stamp WHERE program_key = live;
            RAISE NOTICE 'payroll %: existing % (% lines) set aside as retired:%:%', p, live, n_live, live, stamp;
        END IF;
        UPDATE calc_program SET program_key = live WHERE program_key = staged;
        RAISE NOTICE 'payroll %: % lines promoted % -> %', p, n_staged, staged, live;

    ELSIF current_setting('mig.action') = 'demote' THEN
        IF n_live = 0 OR n_legacy = 0 THEN
            RAISE EXCEPTION 'payroll %: % is not a legacy program (% lines, % with calc_time) - nothing to demote', p, live, n_live, n_legacy;
        END IF;
        IF n_staged > 0 THEN
            RAISE EXCEPTION 'payroll %: % already holds % lines - demoting would leave two staged copies', p, staged, n_staged;
        END IF;
        UPDATE calc_program SET program_key = staged WHERE program_key = live;
        SELECT max(program_key) INTO retired FROM calc_program WHERE program_key LIKE 'retired:' || live || ':%';
        IF retired IS NOT NULL THEN
            UPDATE calc_program SET program_key = live WHERE program_key = retired;
            RAISE NOTICE 'payroll %: % restored to %', p, retired, live;
        END IF;
        RAISE NOTICE 'payroll %: % lines demoted % -> %', p, n_live, live, staged;

    ELSE
        RAISE EXCEPTION 'action must be promote or demote, not %', current_setting('mig.action');
    END IF;
END $$;

SELECT program_key, count(*) AS lines, count(calc_time) AS legacy_lines
FROM calc_program
WHERE program_key IN ('payroll-' || :'target_payroll_id', 'legacy:payroll-' || :'target_payroll_id')
   OR program_key LIKE 'retired:payroll-' || :'target_payroll_id' || ':%'
GROUP BY 1 ORDER BY 1;

COMMIT;
