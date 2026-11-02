<#
    run-migration.ps1 - hop 2 driver. Loads the migration_map, then runs
    sql/10_employees.sql once per tenant with the right search_path + variables.

    PREREQUISITES (see README):
      1. Docker stack up; tenants provisioned via the app (tenant_<slug> exists,
         pipro_core_tenants populated).
      2. Legacy tables dumped into the docker DB as schemas (e.g. legacy_acme) -
         option (b). This script assumes single-DB (source + target both in docker).

    Usage:
      powershell -ExecutionPolicy Bypass -File run-migration.ps1
      powershell -ExecutionPolicy Bypass -File run-migration.ps1 -SystemUserId 1
#>
param(
    [int]$SystemUserId = 1,                                  # DECISION: created_by user for contracts
    [string]$Cutover  = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"),
    [string]$TenantSlug,                                     # only this tenant's map rows (convert.ps1 passes it)
    [switch]$SkipMapLoad                                     # use the map as seeded (convert.ps1); do not reload 00
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

. "$PSScriptRoot\load-settings.ps1"
$cfg             = Import-PiproSettings
$dockerContainer = Get-PiproSetting $cfg 'DOCKER_CONTAINER'
$dockerDb        = Get-PiproSetting $cfg 'DOCKER_DB'
$dockerUser      = Get-PiproSetting $cfg 'DOCKER_USER'
$dockerPassword  = Get-PiproSetting $cfg 'DOCKER_PASSWORD'
$PG   = @('exec','-i','-e',"PGPASSWORD=$dockerPassword",$dockerContainer,'psql','-U',$dockerUser,'-d',$dockerDb)

# --- Docker preflight (do NOT auto-launch; the user starts it manually) --------
# cmd wrapper: PS 5.1 turns native stderr (e.g. docker WARNINGs) into
# NativeCommandError under -ErrorActionPreference Stop; cmd swallows it.
cmd /c "docker info >nul 2>&1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n==> Docker is not running. Start Docker Desktop, wait for 'Engine running', then re-run.`n" -ForegroundColor Yellow
    exit 1
}

# --- Load the routing map (idempotent) -----------------------------------------
# 00_migration_map.sql DROPS the map and re-seeds the single-payroll rehearsal row,
# so it is skipped when convert.ps1 has just seeded the map from payrolls.csv.
if (-not $SkipMapLoad) {
    Write-Host "==> Loading migration_map..." -ForegroundColor Cyan
    Get-Content (Join-Path $here 'sql/00_migration_map.sql') -Raw | docker @PG -v ON_ERROR_STOP=on | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "==> Failed to load migration_map." -ForegroundColor Red; exit 1 }
}
docker exec -e "PGPASSWORD=$dockerPassword" $dockerContainer psql -U $dockerUser -d $dockerDb -q `
    -c "ALTER TABLE migration_map ADD COLUMN IF NOT EXISTS scope TEXT NOT NULL DEFAULT 'full'" | Out-Null
$tenantFilter = if ($TenantSlug) { "WHERE tenant_slug = '$TenantSlug'" } else { '' }

# --- Read the map rows ----------------------------------------------------------
# Full payrolls first, so the tenant's employee-data definitions come from the
# payroll imported in full before any employees-only payroll is added.
$raw = docker exec -e "PGPASSWORD=$dockerPassword" $dockerContainer psql -U $dockerUser -d $dockerDb -t -A -F '|' `
        -c "SELECT legacy_company_schema, legacy_payroll_schema, tenant_slug, target_payroll_id, legacy_payroll_number, scope FROM migration_map $tenantFilter ORDER BY (scope <> 'full'), legacy_company_schema"
if ($LASTEXITCODE -ne 0) { Write-Host "==> Could not read migration_map." -ForegroundColor Red; exit 1 }

$rows = $raw -split "`n" | Where-Object { $_ -match '\|' }
if (-not $rows) { Write-Host "==> migration_map is empty - edit sql/00_migration_map.sql." -ForegroundColor Yellow; exit 1 }

# --- Populate each tenant (10 core -> 20 recurring -> slots -> legacy carry) -------
$scripts = @('sql/10_employees.sql', 'sql/20_recurring.sql', 'sql/40_employee_slots.sql',
             'sql/50_legacy_carry_company.sql', 'sql/55_legacy_carry_payroll.sql', 'sql/56_payroll_tax_method.sql', 'sql/57_calc_program.sql',
             'sql/60_employee_accounts.sql', 'sql/70_employee_tax_status.sql', 'sql/80_payroll_periods.sql') | ForEach-Object { Join-Path $here $_ }
foreach ($row in $rows) {
    $c = $row.Split('|')
    $legacyCompany = $c[0]; $legacyPayroll = $c[1]; $slug = $c[2]; $payrollId = $c[3]; $payrollNumber = $c[4]
    $scope = $c[5].Trim()
    $tenant = "tenant_$slug"
    Write-Host "==> $legacyCompany + $legacyPayroll  ->  $tenant  (payroll $payrollId)" -ForegroundColor Cyan
    # scope 'employees' (convert.ps1: this payroll's employee-data definitions differ from
    # the largest payroll's): its employees only - 10_employees and nothing that
    # depends on the code catalogue.
    $rowScripts = $scripts
    if ($scope -eq 'employees') {
        $rowScripts = @($scripts[0])
        Write-Host "    EMPLOYEES ONLY (its employee-data definitions differ from the full payroll's)" -ForegroundColor Yellow
    }
    foreach ($script in $rowScripts) {
        Get-Content $script -Raw | docker @PG `
            -v ("legacy_company_schema=" + $legacyCompany) `
            -v ("legacy_payroll_schema=" + $legacyPayroll) `
            -v ("tenant_schema=" + $tenant) `
            -v ("target_payroll_id=" + $payrollId) `
            -v ("payroll_number=" + $payrollNumber) `
            -v ("cutover=" + $Cutover) `
            -v ("system_user_id=" + $SystemUserId)
        if ($LASTEXITCODE -ne 0) {
            Write-Host "==> FAILED on $tenant / $(Split-Path $script -Leaf) (rolled back). Fix and re-run.`n" -ForegroundColor Red
            exit 1
        }
    }
}
# --- Once per tenant, after every payroll: steps that need all its payrolls -------
# 65: payslip line labels from the tenant's own catalogue, checked against every
# payroll's payslip layout.
$tenantScripts = @('sql/65_payslip_line_settings.sql') | ForEach-Object { Join-Path $here $_ }
foreach ($slug in ($rows | ForEach-Object { $_.Split('|')[2] } | Sort-Object -Unique)) {
    Write-Host "==> tenant_$slug (all payrolls)" -ForegroundColor Cyan
    foreach ($script in $tenantScripts) {
        Get-Content $script -Raw | docker @PG -v ("tenant_slug=" + $slug) -v ("tenant_schema=tenant_" + $slug)
        if ($LASTEXITCODE -ne 0) {
            Write-Host "==> FAILED on tenant_$slug / $(Split-Path $script -Leaf) (rolled back). Fix and re-run.`n" -ForegroundColor Red
            exit 1
        }
    }
}
Write-Host "`n==> All tenants populated." -ForegroundColor Green
