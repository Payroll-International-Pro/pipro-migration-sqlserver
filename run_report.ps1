<#
    run_report.ps1 - the run-output report (legacy run vs pipro run) for a whole
    tenant, one payroll at a time, driven by payrolls.csv. READ-ONLY apart from the
    compare schema.

    Usage:
      powershell -ExecutionPolicy Bypass -File run_report.ps1 -TenantSlug tau
      powershell -ExecutionPolicy Bypass -File run_report.ps1 -TenantSlug tau -Kind live
      powershell -ExecutionPolicy Bypass -File run_report.ps1 -TenantSlug tau -PeriodEnd 2026-09-30

    -Kind validation (default) compares legacy PW_T_Runf* with pipro previews;
    live compares PW_Runf* with committed payslips.

    Per payroll, in manifest order, snapshots labelled <system>-run-<kind>-p<N>:
      1. export-legacy-run.ps1  the row's source_db -> compare.legacy_runf_*
      2. 95 legacy  -> legacy-run-<kind>-pN
      3. 95 pipro   -> pipro-run-<kind>-pN, for THIS payroll's period
      4. 96 diff, gated against the payroll's master snapshots
         (legacy-before-pN / pipro-before-pN from compare_report.ps1 - run that first)
    The pipro period is the payroll's period ending -PeriodEnd, else the period of
    its latest pipro run, else its first open period. Legacy PW_Runf* has no
    period key; section 0 of each report shows both sides' periods.

    Full output per payroll: reports\<tenant>-run-<kind>-p<N>.txt (gitignored).
    run_report.cmd remains the single-payroll version driven by settings.local.txt.
#>
param(
    [Parameter(Mandatory = $true)][string]$TenantSlug,
    [ValidateSet('live','validation')][string]$Kind = 'validation',
    [string]$PeriodEnd,
    [int]$Tolerance = 10,
    [string]$ManifestPath
)
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\load-settings.ps1"
. "$PSScriptRoot\load-manifest.ps1"

$cfg             = Import-PiproSettings
$dockerContainer = Get-PiproSetting $cfg 'DOCKER_CONTAINER'
$dockerDb        = Get-PiproSetting $cfg 'DOCKER_DB'
$dockerUser      = Get-PiproSetting $cfg 'DOCKER_USER'
$dockerPassword  = Get-PiproSetting $cfg 'DOCKER_PASSWORD'
$tenantSchema    = "tenant_$TenantSlug"

$rows = if ($ManifestPath) { Import-PiproManifest -Path $ManifestPath -TenantSlug $TenantSlug }
        else               { Import-PiproManifest -TenantSlug $TenantSlug }
$current = @($rows | Where-Object { $_.role -eq 'current' })
if ($PeriodEnd -and $PeriodEnd -notmatch '^\d{4}-\d{2}-\d{2}$') { Write-Host "==> -PeriodEnd must be yyyy-mm-dd." -ForegroundColor Red; exit 1 }

# Failures are judged by exit codes from here: psql NOTICEs go to stderr.
$ErrorActionPreference = 'Continue'
cmd /c "docker info >nul 2>&1"
if ($LASTEXITCODE -ne 0) { Write-Host "`n==> Docker is not running. Start Docker Desktop, then re-run.`n" -ForegroundColor Yellow; exit 1 }

$reportDir = Join-Path $PSScriptRoot 'reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

function Invoke-Q([string]$Sql) {
    (& docker exec -e "PGPASSWORD=$dockerPassword" $dockerContainer psql -U $dockerUser -d $dockerDb -t -A -F '|' -c $Sql) | Where-Object { $_ -ne '' }
}
function Invoke-Report([string]$Script, [string[]]$Vars, [string]$Log) {
    $pargs = @('exec','-i','-e',"PGPASSWORD=$dockerPassword",$dockerContainer,'psql','-U',$dockerUser,'-d',$dockerDb,'-v','ON_ERROR_STOP=on','-P','pager=off')
    foreach ($v in $Vars) { $pargs += @('-v', $v) }
    $out = Get-Content (Join-Path $PSScriptRoot $Script) -Raw | & docker @pargs 2>&1 | ForEach-Object { "$_" }
    $ok = ($LASTEXITCODE -eq 0)
    Add-Content -Path $Log -Value $out -Encoding UTF8
    return @{ Ok = $ok; Out = $out }
}

Write-Host ""
Write-Host "===========================================================================" -ForegroundColor Cyan
Write-Host " RUN REPORT  $tenantSchema   kind: $Kind   ($($current.Count) payrolls, read-only)" -ForegroundColor Cyan
Write-Host "===========================================================================" -ForegroundColor Cyan

$failed = $false
foreach ($r in $current) {
    $id     = [int]$r.target_payroll_id
    $schema = $r.company_schema
    $p      = ([string](Invoke-Q "SELECT string_agg(DISTINCT payroll_f04::text, ',') FROM $schema.employees")).Trim()
    if ($p -notmatch '^\d+$') { Write-Host "==> $schema does not hold exactly one payroll ('$p'). Skipped." -ForegroundColor Red; $failed = $true; continue }

    $periodSql = if ($PeriodEnd) {
        "SELECT id || '|' || period_end FROM $tenantSchema.payroll_periods WHERE payroll_id = $id AND period_end = '$PeriodEnd' LIMIT 1"
    } else {
        @"
SELECT COALESCE(
  (SELECT p.id || '|' || p.period_end FROM $tenantSchema.payroll_runs r JOIN $tenantSchema.payroll_periods p ON p.id = r.period_id
    WHERE p.payroll_id = $id ORDER BY r.finished_at DESC NULLS LAST, r.id DESC LIMIT 1),
  (SELECT p.id || '|' || p.period_end FROM $tenantSchema.payroll_periods p
    WHERE p.payroll_id = $id AND p.status = 'open' ORDER BY p.period_end LIMIT 1))
"@
    }
    $period = [string](Invoke-Q $periodSql)
    if (-not $period) { Write-Host "==> payroll $id has no period$(if ($PeriodEnd) { " ending $PeriodEnd" }). Skipped." -ForegroundColor Red; $failed = $true; continue }
    $periodId, $periodEndFound = $period.Split('|')

    $legacy = "legacy-run-$Kind-p$p"
    $pipro  = "pipro-run-$Kind-p$p"
    $log    = Join-Path $reportDir "$TenantSlug-run-$Kind-p$p.txt"
    Set-Content -Path $log -Value "Run report $tenantSchema payroll $p ($($r.source_db) / $schema), kind $Kind, pipro period $periodId ending $periodEndFound, $(Get-Date -Format s)" -Encoding UTF8

    Write-Host ""
    Write-Host "--- Payroll $p   $($r.source_db)   pipro period $periodId ending $periodEndFound ---------------" -ForegroundColor Cyan

    Write-Host "    [1/4] legacy $Kind run export ($($r.source_db))" -ForegroundColor DarkGray
    $exp = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'export-legacy-run.ps1') -Kind $Kind -SqlDatabase $r.source_db 2>&1 | ForEach-Object { "$_" }
    Add-Content -Path $log -Value $exp -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { Write-Host "    export failed - see $log" -ForegroundColor Red; $failed = $true; continue }

    $steps = @(
        @{ N = '2/4'; Label = "snapshot $legacy"; Script = 'sql/95_run_snapshot.sql';
           Vars = @("snap=$legacy", 'system=legacy', "kind=$Kind", "tenant_schema=$tenantSchema", "period_id=$periodId") },
        @{ N = '3/4'; Label = "snapshot $pipro";  Script = 'sql/95_run_snapshot.sql';
           Vars = @("snap=$pipro",  'system=pipro',  "kind=$Kind", "tenant_schema=$tenantSchema", "period_id=$periodId") },
        @{ N = '4/4'; Label = 'run diff';         Script = 'sql/96_run_diff.sql';
           Vars = @("a=$legacy", "b=$pipro", "master_a=legacy-before-p$p", "master_b=pipro-before-p$p", "tolerance=$Tolerance") }
    )
    foreach ($s in $steps) {
        Write-Host "    [$($s.N)] $($s.Label)" -ForegroundColor DarkGray
        Add-Content -Path $log -Value "`n=================== [$($s.N)] $($s.Label) ===================" -Encoding UTF8
        $res = Invoke-Report $s.Script $s.Vars $log
        if (-not $res.Ok) {
            Write-Host "    FAILED - see $log" -ForegroundColor Red
            $res.Out | Select-Object -Last 6 | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
            $failed = $true; break
        }
    }
    if ($failed) { continue }

    # CurrentRunDate is a legacy day number (epoch 1799-12-31), shown as a date.
    $label = Invoke-Q @"
SELECT 'legacy run ' || COALESCE(current_run::text, '?') || ' / ' ||
       COALESCE(CASE WHEN current_run_date::text ~ '^[0-9]+$' THEN (DATE '1799-12-31' + current_run_date::text::int)::text
                     ELSE current_run_date::text END, '?')
FROM compare.legacy_run_label WHERE kind = '$Kind' LIMIT 1
"@
    $gate  = $res.Out | Where-Object { $_ -match '\b(nothing_to_compare|legacy_run_missing|pipro_run_missing|totals_only_available|master_differs|shape_differs|full_detail)\b' } | Select-Object -First 1
    $gate  = if ($gate -match '\b(nothing_to_compare|legacy_run_missing|pipro_run_missing|totals_only_available|master_differs|shape_differs|full_detail)\b') { $Matches[1] } else { '?' }
    Write-Host "          periods    : $label   vs   pipro $periodEndFound"
    Write-Host "          gate       : $gate"
    $totals = Invoke-Q @"
SELECT t.metric || ': legacy ' || COALESCE(to_char(sum(a.value_num), 'FM999G999G990D00'), '-')
       || '  pipro ' || COALESCE(to_char(sum(b.value_num), 'FM999G999G990D00'), '-')
       || '  (' || count(*) FILTER (WHERE a.value_num IS DISTINCT FROM b.value_num) || ' employees differ)'
FROM (SELECT DISTINCT metric, employee_code FROM compare.run_total WHERE snap IN ('$legacy','$pipro')) t
LEFT JOIN compare.run_total a ON a.snap = '$legacy' AND a.metric = t.metric AND a.employee_code = t.employee_code
LEFT JOIN compare.run_total b ON b.snap = '$pipro'  AND b.metric = t.metric AND b.employee_code = t.employee_code
GROUP BY t.metric ORDER BY t.metric
"@
    foreach ($t in $totals) { Write-Host "          $t" }
    Write-Host "          full report: $log" -ForegroundColor DarkGray
}

Write-Host ""
if ($failed) { Write-Host "==> Finished WITH FAILURES (see above). Nothing outside the compare schema was modified." -ForegroundColor Red; exit 1 }
Write-Host "==> Finished. Nothing outside the compare schema was modified." -ForegroundColor Green
