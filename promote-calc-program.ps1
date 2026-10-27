<#
    promote-calc-program.ps1 - switch a tenant's payrolls onto their imported
    legacy calc programs (or back). Runs sql/58_promote_calc_program.sql once per
    payroll in payrolls.csv. Not part of convert.ps1: promote a payroll only after
    tracing its staged program against legacy.

    Usage:
      powershell -ExecutionPolicy Bypass -File promote-calc-program.ps1 -TenantSlug tau
      powershell -ExecutionPolicy Bypass -File promote-calc-program.ps1 -TenantSlug tau -PayrollId 2
      powershell -ExecutionPolicy Bypass -File promote-calc-program.ps1 -TenantSlug tau -Undo

    WRITES calc_program in the tenant: after promotion every run of the payroll,
    previews included, uses the client's program. Each payroll is its own
    transaction; nothing is deleted (see the SQL file's header).
#>
param(
    [Parameter(Mandatory = $true)][string]$TenantSlug,
    [int[]]$PayrollId,
    [switch]$Undo,
    [switch]$Yes,
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
$action          = if ($Undo) { 'demote' } else { 'promote' }

$rows = if ($ManifestPath) { Import-PiproManifest -Path $ManifestPath -TenantSlug $TenantSlug }
        else               { Import-PiproManifest -TenantSlug $TenantSlug }
$ids = @($rows | Where-Object { $_.role -eq 'current' } | ForEach-Object { [int]$_.target_payroll_id })
if ($PayrollId) {
    $unknown = @($PayrollId | Where-Object { $ids -notcontains $_ })
    if ($unknown.Count) { Write-Host "==> Payroll(s) $($unknown -join ', ') are not in the manifest for '$TenantSlug'." -ForegroundColor Red; exit 1 }
    $ids = $PayrollId
}

$ErrorActionPreference = 'Continue'   # psql NOTICEs go to stderr; judged by exit code below
cmd /c "docker info >nul 2>&1"
if ($LASTEXITCODE -ne 0) { Write-Host "`n==> Docker is not running. Start Docker Desktop, then re-run.`n" -ForegroundColor Yellow; exit 1 }

Write-Host ""
Write-Host " $($action.ToUpper()) the legacy calc program for $tenantSchema payroll(s): $($ids -join ', ')" -ForegroundColor Cyan
if ($action -eq 'promote') {
    Write-Host " Every later run of these payrolls - previews included - will use the client's program." -ForegroundColor Yellow
}
if (-not $Yes) {
    $answer = Read-Host "Type $($action.ToUpper()) to continue"
    if ($answer -ne $action.ToUpper()) { Write-Host "==> Stopped. Nothing was changed." -ForegroundColor Yellow; exit 0 }
}

$failed = $false
foreach ($id in $ids) {
    Write-Host ""
    Write-Host "--- payroll $id" -ForegroundColor Cyan
    Get-Content (Join-Path $PSScriptRoot 'sql/58_promote_calc_program.sql') -Raw |
        docker exec -i -e "PGPASSWORD=$dockerPassword" $dockerContainer psql -U $dockerUser -d $dockerDb `
            -q -P pager=off -v ON_ERROR_STOP=on -v "tenant_schema=$tenantSchema" -v "target_payroll_id=$id" -v "action=$action" 2>&1 |
        ForEach-Object { "    $_" }
    if ($LASTEXITCODE -ne 0) { Write-Host "    FAILED - payroll $id is unchanged." -ForegroundColor Red; $failed = $true }
}
Write-Host ""
if ($failed) { exit 1 }
Write-Host "==> Done." -ForegroundColor Green
