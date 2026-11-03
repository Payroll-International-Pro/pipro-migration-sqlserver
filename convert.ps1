<#
    convert.ps1 - drives a whole client conversion from payrolls.csv.

    Usage:
      powershell -ExecutionPolicy Bypass -File convert.ps1 -TenantSlug acme
      powershell -ExecutionPolicy Bypass -File convert.ps1 -TenantSlug acme -SkipReset

    WHAT IT DOES, and what it deliberately leaves to you:

      1. Loads and validates payrolls.csv (see load-manifest.ps1).
      2. Prints the plan and waits.
      3. Resets the tenant ONCE - not per payroll, or the second payroll would
         wipe the first.
      4. For each payroll, in manifest order:
           - waits while YOU run PostgresImport against that source database
           - copies the two interim schemas into docker under the manifest's
             names, so the next PostgresImport run cannot overwrite them
           - VERIFIES the payroll number in the data matches what the manifest
             declared
      5. Seeds migration_map from the manifest.
      6. Merges the payrolls' employee-data catalogues (amount codes, alpha,
         dates, registers) into ONE for the tenant - sql/15_catalogue_merge.sql.
         It reports every ordinal the payrolls disagree on and STOPS if any
         ordinal holding values in two payrolls has two names; name those in
         catalogue-overrides.csv and re-run. Then writes the merged catalogues.
      7. Runs the import chain (run-migration.ps1) for every mapped payroll.

    Step 4 pauses so you can run PostgresImport for that payroll, writing to the
    schema name(s) the manifest gives it. Each payroll has its own desktop schema,
    so you may also run all of them beforehand and just press Enter at each pause.
    PostgresImport drops and recreates its target schemas on every run, so two
    payrolls must never share one.

    WRITES. It empties and repopulates the tenant. Reports come afterwards, from
    compare_report.cmd and run_report.cmd.

    role=history rows are validated and listed, then skipped - not implemented.
#>
param(
    [Parameter(Mandatory = $true)][string]$TenantSlug,
    [switch]$SkipReset,
    [string]$ManifestPath,
    [string]$OverridesPath
)
# Resolved here, not as the parameter default: PS 5.1 leaves $PSScriptRoot empty inside param().
if (-not $OverridesPath) { $OverridesPath = Join-Path $PSScriptRoot 'catalogue-overrides.csv' }
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\load-settings.ps1"
. "$PSScriptRoot\load-manifest.ps1"

$cfg             = Import-PiproSettings
$dockerContainer = Get-PiproSetting $cfg 'DOCKER_CONTAINER'
$dockerDb        = Get-PiproSetting $cfg 'DOCKER_DB'
$dockerUser      = Get-PiproSetting $cfg 'DOCKER_USER'
$dockerPassword  = Get-PiproSetting $cfg 'DOCKER_PASSWORD'
$tenantSchema    = "tenant_$TenantSlug"

function Invoke-Psql {
    param([string]$Sql, [switch]$Quiet)
    $out = $Sql | docker exec -i -e "PGPASSWORD=$dockerPassword" $dockerContainer `
                  psql -U $dockerUser -d $dockerDb -v ON_ERROR_STOP=on -t -A
    if ($LASTEXITCODE -ne 0) { throw "psql failed: $Sql" }
    if (-not $Quiet) { return $out }
}

function Confirm-Step {
    param([string]$Prompt, [string]$Expect = '')
    Write-Host ""
    if ($Expect) {
        $answer = Read-Host "$Prompt (type $Expect to continue)"
        if ($answer -ne $Expect) { Write-Host "==> Stopped. Nothing further has run." -ForegroundColor Yellow; exit 0 }
    } else {
        Read-Host "$Prompt (Enter to continue, Ctrl+C to stop)" | Out-Null
    }
}

cmd /c "docker info >nul 2>&1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n==> Docker is not running. Start Docker Desktop, then re-run.`n" -ForegroundColor Yellow
    exit 1
}

# --- 1. Manifest -----------------------------------------------------------------
$rows = if ($ManifestPath) { Import-PiproManifest -Path $ManifestPath -TenantSlug $TenantSlug }
        else               { Import-PiproManifest -TenantSlug $TenantSlug }
$current = @($rows | Where-Object { $_.role -eq 'current' })
$history = @($rows | Where-Object { $_.role -eq 'history' })

if ($current.Count -eq 0) {
    Write-Host "==> No 'current' rows for tenant '$TenantSlug'. Nothing to convert." -ForegroundColor Red
    exit 1
}

# --- 2. The plan -----------------------------------------------------------------
Write-Host ""
Write-Host "===========================================================================" -ForegroundColor Cyan
Write-Host " CONVERT  ->  $tenantSchema" -ForegroundColor Cyan
Write-Host "===========================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host (" {0,-22} {1,-16} {2,-16} {3,8} {4,8}" -f 'source database','company schema','payroll schema','payroll','target')
foreach ($r in $current) {
    Write-Host (" {0,-22} {1,-16} {2,-16} {3,8} {4,8}" -f `
        $r.source_db, $r.company_schema, $r.payroll_schema,
        $(if ($r.legacy_payroll_number) { $r.legacy_payroll_number } else { '(data)' }), $r.target_payroll_id)
}
Write-Host ""
Write-Host " $($current.Count) payroll(s) to convert." -ForegroundColor Green
if ($history.Count -gt 0) {
    Write-Host " $($history.Count) history row(s) validated and SKIPPED (not implemented):" -ForegroundColor Yellow
    foreach ($h in $history) { Write-Host "    $($h.source_db)  tax year $($h.tax_year)" -ForegroundColor DarkGray }
}

# The tenant and its payrolls are provisioned by the APP, never by these scripts.
# Check they exist before doing anything destructive.
$exists = Invoke-Psql "SELECT count(*) FROM information_schema.schemata WHERE schema_name = '$tenantSchema'"
if ([int]$exists -eq 0) {
    Write-Host "`n==> No schema '$tenantSchema'. Provision the tenant through the app first.`n" -ForegroundColor Red
    exit 1
}
foreach ($r in $current) {
    $p = Invoke-Psql "SELECT count(*) FROM $tenantSchema.payrolls WHERE id = $($r.target_payroll_id)"
    if ([int]$p -eq 0) {
        Write-Host "`n==> $tenantSchema has no payrolls row with id $($r.target_payroll_id)" -ForegroundColor Red
        Write-Host "    (needed by manifest row '$($r.source_db)'). Create it through the app.`n" -ForegroundColor Yellow
        exit 1
    }
}
Write-Host " Tenant and all target payroll rows exist." -ForegroundColor Green

Confirm-Step "Proceed with this plan?"

# --- 3. Reset --------------------------------------------------------------------
if ($SkipReset) {
    Write-Host "`n==> -SkipReset given: the tenant keeps its current data." -ForegroundColor Yellow
    Write-Host "    Only use this to resume a conversion you already reset for." -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "---------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host " RESET $tenantSchema - empties every employee- and run-scoped table," -ForegroundColor Yellow
    Write-Host " removes the login users this import minted, and keeps the eight" -ForegroundColor Yellow
    Write-Host " configuration tables provisioning created. Not reversible." -ForegroundColor Yellow
    Write-Host " It runs ONCE for the tenant, before any payroll." -ForegroundColor Yellow
    Write-Host "---------------------------------------------------------------------------" -ForegroundColor Yellow
    Confirm-Step "Reset $tenantSchema" -Expect 'RESET'

    Get-Content (Join-Path $PSScriptRoot 'sql/09_reset_tenant.sql') -Raw |
        docker exec -i -e "PGPASSWORD=$dockerPassword" $dockerContainer psql -U $dockerUser -d $dockerDb `
            -v ON_ERROR_STOP=on -v "tenant_schema=$tenantSchema" -v "confirm=RESET"
    if ($LASTEXITCODE -ne 0) { Write-Host "==> Reset failed." -ForegroundColor Red; exit 1 }
}

# --- 4. Per-payroll: PostgresImport, then park the schemas in docker -------------
$n = 0
foreach ($r in $current) {
    $n++
    Write-Host ""
    Write-Host "===========================================================================" -ForegroundColor Cyan
    Write-Host " PAYROLL $n of $($current.Count):  $($r.source_db)  ->  target payroll $($r.target_payroll_id)" -ForegroundColor Cyan
    Write-Host "===========================================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host " Now, outside this script:" -ForegroundColor Yellow
    Write-Host "   1. restore '$($r.source_db)' to SQL Server" -ForegroundColor Yellow
    Write-Host "   2. run PostgresImport against it, with its COMPANY schema set to" -ForegroundColor Yellow
    Write-Host "      '$($r.company_schema)' and its PAYROLL schema set to '$($r.payroll_schema)'" -ForegroundColor Yellow
    Write-Host "      (already done? just continue)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host " Then this script copies those desktop schemas into docker under the same names." -ForegroundColor DarkGray
    Confirm-Step "PostgresImport finished for '$($r.source_db)'?"

    & (Join-Path $PSScriptRoot 'refresh-interim.ps1') `
        -Schema $r.company_schema -SchemaTarget $r.company_schema `
        -PayrollSource $r.payroll_schema -PayrollTarget $r.payroll_schema
    if ($LASTEXITCODE -ne 0) { Write-Host "==> Refresh failed for $($r.source_db)." -ForegroundColor Red; exit 1 }

    # The payroll number comes FROM THE DATA (every interim employees row carries
    # it in payroll_f04; the sql/ scripts read it the same way). A number typed in
    # the manifest is optional and, when present, only checked against the data.
    $found = Invoke-Psql "SELECT string_agg(DISTINCT payroll_f04::text, ',') FROM $($r.company_schema).employees"
    $found = ([string]$found).Trim()
    if ($found -notmatch '^\d+$') {
        Write-Host ""
        Write-Host "==> NO SINGLE PAYROLL NUMBER in $($r.company_schema).employees.payroll_f04: '$found'." -ForegroundColor Red
        Write-Host "    One imported database must hold exactly one payroll. Stopping." -ForegroundColor Yellow
        exit 1
    }
    if (-not $r.legacy_payroll_number) {
        $r.legacy_payroll_number = $found
        Write-Host "    payroll number $found read from the data." -ForegroundColor Green
        continue
    }
    if ($found -ne $r.legacy_payroll_number) {
        Write-Host ""
        Write-Host "==> PAYROLL NUMBER MISMATCH for '$($r.source_db)'." -ForegroundColor Red
        Write-Host "    Manifest says $($r.legacy_payroll_number); the data says '$found'." -ForegroundColor Red
        Write-Host "    Either the wrong database was imported, or the manifest is wrong." -ForegroundColor Yellow
        Write-Host "    Stopping - importing this would attribute employees to the wrong payroll." -ForegroundColor Yellow
        exit 1
    }
    Write-Host "    payroll number $found confirmed against the data." -ForegroundColor Green
}

# Two payrolls of one tenant with the same number would share employee codes
# ("<payroll>/<EmpNo>"), so the second would land on the first's employees.
$dupe = $current | Group-Object legacy_payroll_number | Where-Object { $_.Count -gt 1 } | Select-Object -First 1
if ($dupe) {
    Write-Host ""
    Write-Host "==> Payroll number $($dupe.Name) appears in more than one database: $(($dupe.Group | ForEach-Object source_db) -join ', ')." -ForegroundColor Red
    Write-Host "    Each payroll of a tenant needs its own number. Stopping." -ForegroundColor Yellow
    exit 1
}

# Every payroll is imported in full. Disagreements between their employee-data
# catalogues are settled by the catalogue merge (step 6), not by cutting payrolls
# down to employees only.
foreach ($r in $current) { $r | Add-Member -NotePropertyName scope -NotePropertyValue 'full' -Force }

# --- 5. Seed migration_map -------------------------------------------------------
Write-Host ""
Write-Host "==> Seeding migration_map from the manifest..." -ForegroundColor Cyan
$values = ($current | ForEach-Object {
    "('$($_.company_schema)','$($_.payroll_schema)','$($_.tenant_slug)',$($_.target_payroll_id),$($_.legacy_payroll_number),'$($_.scope)')"
}) -join ",`n    "
Invoke-Psql @"
CREATE TABLE IF NOT EXISTS migration_map (
    legacy_company_schema TEXT PRIMARY KEY,
    legacy_payroll_schema TEXT NOT NULL,
    tenant_slug           TEXT NOT NULL,
    target_payroll_id     INTEGER NOT NULL,
    legacy_payroll_number INTEGER NOT NULL DEFAULT 1);
ALTER TABLE migration_map ADD COLUMN IF NOT EXISTS scope TEXT NOT NULL DEFAULT 'full';
DELETE FROM migration_map WHERE tenant_slug = '$TenantSlug';
INSERT INTO migration_map (legacy_company_schema, legacy_payroll_schema, tenant_slug, target_payroll_id, legacy_payroll_number, scope) VALUES
    $values;
"@ -Quiet
Invoke-Psql "SELECT legacy_company_schema || ' + ' || legacy_payroll_schema || ' -> ' || tenant_slug || ' payroll ' || target_payroll_id || ' (' || scope || ')' FROM migration_map WHERE tenant_slug = '$TenantSlug' ORDER BY target_payroll_id" |
    ForEach-Object { if ($_) { Write-Host "    $_" -ForegroundColor DarkGray } }

# --- 6. Merge the employee-data catalogues --------------------------------------
# One tenant, one catalogue per kind of employee data; every payroll had its own.
# 15_catalogue_merge.sql decides each ordinal (see its header) and reports every
# disagreement. Ordinals that hold values in two payrolls under two names cannot
# be decided by a script: they are named in catalogue-overrides.csv.
function Invoke-CatalogueMerge([string]$Apply) {
    Get-Content (Join-Path $PSScriptRoot 'sql/15_catalogue_merge.sql') -Raw |
        docker exec -i -e "PGPASSWORD=$dockerPassword" $dockerContainer psql -U $dockerUser -d $dockerDb `
            -q -P pager=off -v ON_ERROR_STOP=on -v "tenant_slug=$TenantSlug" -v "tenant_schema=$tenantSchema" -v "apply=$Apply" |
            Out-Host    # print the report; otherwise it becomes this function's return value
    return ($LASTEXITCODE -eq 0)
}

$overrides = @()
if (Test-Path $OverridesPath) {
    $ovLines = Get-Content $OverridesPath | Where-Object { $_ -match '\S' -and $_.TrimStart() -notmatch '^#' }
    if ($ovLines.Count -ge 2) {
        $overrides = @($ovLines | ConvertFrom-Csv | Where-Object { $_.tenant_slug.Trim() -eq $TenantSlug })
    }
}
$ovProblems = @()
foreach ($o in $overrides) {
    if ($o.catalogue.Trim() -notin @('amounts','alpha','dates','precision')) { $ovProblems += "catalogue '$($o.catalogue)' must be amounts, alpha, dates or precision" }
    if ($o.ordinal_no.Trim() -notmatch '^\d+$') { $ovProblems += "ordinal_no '$($o.ordinal_no)' is not a number" }
    if (-not $o.name.Trim()) { $ovProblems += "$($o.catalogue) $($o.ordinal_no): name is empty" }
}
if ($ovProblems.Count -gt 0) {
    Write-Host "`n==> $OverridesPath has problems:" -ForegroundColor Red
    $ovProblems | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
$ovValues = ($overrides | ForEach-Object {
    $q = { param($s) "'" + ([string]$s).Trim().Replace("'", "''") + "'" }
    "($(& $q $TenantSlug),$(& $q $_.catalogue),$([int]$_.ordinal_no),$(& $q $_.name),$(& $q $_.note))"
}) -join ",`n    "
Invoke-Psql @"
CREATE SCHEMA IF NOT EXISTS migration;
CREATE TABLE IF NOT EXISTS migration.catalogue_override (
    tenant_slug TEXT NOT NULL, catalogue TEXT NOT NULL, ordinal_no INTEGER NOT NULL,
    name TEXT NOT NULL, note TEXT, PRIMARY KEY (tenant_slug, catalogue, ordinal_no));
DELETE FROM migration.catalogue_override WHERE tenant_slug = '$TenantSlug';
$(if ($ovValues) { "INSERT INTO migration.catalogue_override VALUES`n    $ovValues;" })
"@ -Quiet
Write-Host ""
Write-Host "==> Merging employee-data catalogues ($($overrides.Count) override(s) from $(Split-Path $OverridesPath -Leaf))..." -ForegroundColor Cyan
if (-not (Invoke-CatalogueMerge '0')) { Write-Host "==> Catalogue merge report failed." -ForegroundColor Red; exit 1 }

$blocking = Invoke-Psql "SELECT catalogue || ' ' || ordinal_no || ' (' || verdict || ')' FROM migration.catalogue_merge WHERE tenant_slug = '$TenantSlug' AND verdict LIKE 'CONFLICT%' ORDER BY catalogue, ordinal_no"
$blocking = @($blocking | Where-Object { $_ })
if ($blocking.Count -gt 0) {
    Write-Host ""
    Write-Host "---------------------------------------------------------------------------" -ForegroundColor Red
    Write-Host " $($blocking.Count) catalogue conflict(s) - the tenant has been reset but NOT populated:" -ForegroundColor Red
    $blocking | ForEach-Object { Write-Host "     $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host " CONFLICT_NAME: add a row to $(Split-Path $OverridesPath -Leaf) naming the ordinal" -ForegroundColor Yellow
    Write-Host "   (see catalogue-overrides.example.csv), then re-run convert." -ForegroundColor Yellow
    Write-Host " CONFLICT_DUPLICATE_NAME: two ordinals holding values ended up with one name" -ForegroundColor Yellow
    Write-Host "   (notes say which); override all but one of them with a distinct name." -ForegroundColor Yellow
    Write-Host " CONFLICT_TYPE: the payrolls use the ordinal for different kinds of value;" -ForegroundColor Yellow
    Write-Host "   renumber it in one legacy payroll first. No override can fix that." -ForegroundColor Yellow
    Write-Host "---------------------------------------------------------------------------" -ForegroundColor Red
    exit 1
}
Confirm-Step "Write the merged catalogues above and run the import chain for these payroll(s)?"
if (-not (Invoke-CatalogueMerge '1')) { Write-Host "==> Writing the merged catalogues failed." -ForegroundColor Red; exit 1 }

# --- 7. The import chain ---------------------------------------------------------
# -SkipMapLoad: run-migration.ps1 otherwise reloads sql/00_migration_map.sql, which
# drops the map and re-seeds the single-payroll rehearsal row, discarding the rows
# just seeded from the manifest.
& (Join-Path $PSScriptRoot 'run-migration.ps1') -TenantSlug $TenantSlug -SkipMapLoad
if ($LASTEXITCODE -ne 0) { Write-Host "==> Import chain failed." -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "===========================================================================" -ForegroundColor Green
Write-Host " Conversion finished. NOTHING HAS BEEN VERIFIED." -ForegroundColor Green
Write-Host ""
Write-Host " Check it with the read-only reports:" -ForegroundColor Green
Write-Host "     compare_report.cmd before     employee master data" -ForegroundColor Green
Write-Host "     run_report.cmd validation     run output, once both sides have run" -ForegroundColor Green
Write-Host "===========================================================================" -ForegroundColor Green
