<#
    refresh-interim.ps1 - hop 1.5. Copies the interim (desktop Postgres) schemas
    into the docker Postgres, replacing the previous copies.

    WHY THIS EXISTS: PostgresImport writes to the DESKTOP Postgres, but the migration
    scripts and the parity report both read a COPY of it inside docker. Re-running the
    import does NOT change the docker copy, so a report run straight after an import
    silently re-measures the OLD data.

    BOTH SCHEMAS, ALWAYS. The interim database is split the way DataDictionary splits
    it: a COMPANY schema (employees and their values) and a PAYROLL schema (calendar,
    calculation programs, tax codes). Refreshing only the company one leaves
    80_payroll_periods building the calendar from a stale settings_calendar - which is
    exactly how a re-import can appear to ignore the legacy calendar.

    THE PAYROLL SCHEMA IS RENAMED ON THE WAY IN. On the desktop it is called 'pipro';
    a schema of that name in docker shadows 'public' for the app's own 'pipro' user and
    makes every tenant appear to vanish (this has happened once). It is therefore
    restored and renamed inside ONE transaction, so no other session ever sees a
    committed schema called 'pipro'.

    VERSION MISMATCH (the reason this is not a one-liner): the desktop server is
    PostgreSQL 18 and the docker server is pinned to 16.
      * pg_dump refuses to read a server NEWER than itself, so the container's
        bundled pg_dump 16 cannot dump the desktop DB -- we use the local
        PostgreSQL 18 client instead, found automatically below.
      * Restoring 18 -> 16 is the unsupported direction. In practice the only thing
        that breaks for a plain table+data dump is the preamble line
        `SET transaction_timeout = 0;` (new in PG17), which a 16 server rejects.
        That line is stripped before the restore. This is the same incompatibility
        pipro-app's Dockerfile pins postgresql-client-16 to avoid.
      * If the restore ever fails on some OTHER unrecognized parameter, add it to
        $incompatibleSettings rather than loosening ON_ERROR_STOP.

    DESTRUCTIVE: drops and recreates both target schemas in docker. Tenant schemas
    are untouched.

    Connection details live in settings.local.txt (copy settings.example.txt).
    Parameters override the file for a one-off run.

    Usage:
      powershell -ExecutionPolicy Bypass -File refresh-interim.ps1
      powershell -ExecutionPolicy Bypass -File refresh-interim.ps1 -Schema other_client
#>
param(
    [string]$Schema,
    # Docker name for the company schema. Defaults to $Schema. convert.ps1 passes
    # the manifest's name, because PostgresImport always writes the same desktop
    # name ('airplane') whichever client it imported.
    [string]$SchemaTarget,
    [string]$DesktopHost,
    [int]   $DesktopPort,
    [string]$DesktopDb,
    [string]$DesktopUser,
    [string]$DesktopPassword,
    [string]$PgDumpPath,
    # Both default to settings.local.txt. convert.ps1 passes them per payroll,
    # because PostgresImport always writes the same two schema names on the
    # desktop and each payroll has to be parked separately in docker.
    [string]$PayrollSource,
    [string]$PayrollTarget
)
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\load-settings.ps1"
$cfg = Import-PiproSettings

if (-not $Schema)          { $Schema          = Get-PiproSetting $cfg 'INTERIM_SCHEMA' }
if (-not $SchemaTarget)    { $SchemaTarget    = $Schema }
if (-not $DesktopHost)     { $DesktopHost     = Get-PiproSetting $cfg 'INTERIM_HOST' }
if (-not $DesktopPort)     { $DesktopPort     = [int](Get-PiproSetting $cfg 'INTERIM_PORT') }
if (-not $DesktopDb)       { $DesktopDb       = Get-PiproSetting $cfg 'INTERIM_DB' }
if (-not $DesktopUser)     { $DesktopUser     = Get-PiproSetting $cfg 'INTERIM_USER' }
if (-not $DesktopPassword) { $DesktopPassword = Get-PiproSetting $cfg 'INTERIM_PASSWORD' -AllowEmpty }

if (-not $PayrollSource) { $PayrollSource = Get-PiproSetting $cfg 'INTERIM_PAYROLL_SCHEMA' }
if (-not $PayrollTarget) { $PayrollTarget = Get-PiproSetting $cfg 'INTERIM_PAYROLL_TARGET' }
$payrollSource = $PayrollSource
$payrollTarget = $PayrollTarget
if ($payrollTarget -eq 'pipro') {
    Write-Host "==> INTERIM_PAYROLL_TARGET must not be 'pipro' - a schema of that name" -ForegroundColor Red
    Write-Host "    shadows 'public' for the app's own 'pipro' user and hides every tenant." -ForegroundColor Red
    exit 1
}

$dockerContainer = Get-PiproSetting $cfg 'DOCKER_CONTAINER'
$dockerDb        = Get-PiproSetting $cfg 'DOCKER_DB'
$dockerUser      = Get-PiproSetting $cfg 'DOCKER_USER'
$dockerPassword  = Get-PiproSetting $cfg 'DOCKER_PASSWORD'

# Settings emitted by a newer pg_dump that an older server will not accept.
$incompatibleSettings = @('transaction_timeout')
$stripExpr = ($incompatibleSettings | ForEach-Object { "/^SET $_ = /d" }) -join '; '

cmd /c "docker info >nul 2>&1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n==> Docker is not running. Start Docker Desktop, then re-run.`n" -ForegroundColor Yellow
    exit 1
}

# --- Locate a pg_dump at least as new as the desktop server ---------------------
if (-not $PgDumpPath) {
    $candidates = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\pg_dump.exe' -ErrorAction SilentlyContinue |
                  Sort-Object { [int]($_.Directory.Parent.Name) } -Descending
    if (-not $candidates) {
        Write-Host "==> No local pg_dump found under C:\Program Files\PostgreSQL. Pass -PgDumpPath." -ForegroundColor Red
        exit 1
    }
    $PgDumpPath = $candidates[0].FullName
}
$psqlPath = Join-Path (Split-Path $PgDumpPath) 'psql.exe'
Write-Host "==> Using $PgDumpPath" -ForegroundColor DarkGray

if (-not $DesktopPassword) {
    $secure = Read-Host -Prompt "Desktop Postgres password for $DesktopUser" -AsSecureString
    $DesktopPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}

function Sync-Schema {
    param([string]$Source, [string]$Target)

    Write-Host ""
    Write-Host "==> $DesktopDb.$Source  ->  docker.$Target" -ForegroundColor Cyan

    # Check the source BEFORE dropping anything on the target, so a bad name or an
    # unreachable desktop leaves the existing copy intact.
    $tableCount = & $psqlPath -h $DesktopHost -p $DesktopPort -U $DesktopUser -d $DesktopDb -t -A `
        -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = '$Source'"
    if (($LASTEXITCODE -ne 0) -or ([int]$tableCount -le 0)) {
        Write-Host "    Could not read schema '$Source' on the desktop DB. Nothing was changed." -ForegroundColor Red
        return $false
    }
    Write-Host "    $tableCount tables on the desktop." -ForegroundColor DarkGray

    $dumpFile = Join-Path $env:TEMP "interim-$Source.sql"
    & $PgDumpPath -h $DesktopHost -p $DesktopPort -U $DesktopUser -d $DesktopDb `
                  -n $Source --no-owner --no-privileges --no-tablespaces -f $dumpFile
    if ($LASTEXITCODE -ne 0) { Write-Host "    pg_dump failed. Nothing was changed." -ForegroundColor Red; return $false }
    Write-Host ("    dumped {0:N1} MB" -f ((Get-Item $dumpFile).Length / 1MB)) -ForegroundColor DarkGray

    cmd /c "docker cp `"$dumpFile`" ${dockerContainer}:/tmp/interim-$Source.sql >nul 2>&1"
    if ($LASTEXITCODE -ne 0) { Write-Host "    docker cp failed. Nothing was changed." -ForegroundColor Red; return $false }

    # The DROP / restore / RENAME are concatenated into one file and run with a
    # single -f under --single-transaction. Passing them as separate -c arguments
    # through `sh -c` needs line continuations, and the quoting does not survive.
    # One transaction means the transient schema named $Source is never visible to
    # another session - which is what makes renaming 'pipro' safe.
    #
    # When renaming, a docker schema that already carries the SOURCE name (e.g. the
    # parked 'airplane' rehearsal copy while converting another client) is moved
    # aside for the restore and put back afterwards, not dropped.
    $pre  = "DROP SCHEMA IF EXISTS $Target CASCADE;"
    $post = ""
    if ($Source -eq 'pipro') {
        # Never preserve a stray docker 'pipro' - it shadows 'public' (see above).
        $pre  = "$pre DROP SCHEMA IF EXISTS $Source CASCADE;"
        $post = "ALTER SCHEMA $Source RENAME TO $Target;"
    } elseif ($Source -ne $Target) {
        $parked = "${Source}__parked"
        $pre  = "$pre`nDROP SCHEMA IF EXISTS $parked CASCADE;" +
                "`nDO `$`$ BEGIN IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = '$Source') THEN ALTER SCHEMA $Source RENAME TO $parked; END IF; END `$`$;"
        $post = "ALTER SCHEMA $Source RENAME TO $Target;" +
                "`nDO `$`$ BEGIN IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = '$parked') THEN ALTER SCHEMA $parked RENAME TO $Source; END IF; END `$`$;"
    }

    # pre/post go in as files: the DO blocks' quotes and dollars do not survive sh -c.
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $preFile  = Join-Path $env:TEMP "pre-$Source.sql"
    $postFile = Join-Path $env:TEMP "post-$Source.sql"
    [IO.File]::WriteAllText($preFile,  "$pre`n",  $utf8)
    [IO.File]::WriteAllText($postFile, "$post`n", $utf8)
    cmd /c "docker cp `"$preFile`" ${dockerContainer}:/tmp/pre-$Source.sql >nul 2>&1"
    cmd /c "docker cp `"$postFile`" ${dockerContainer}:/tmp/post-$Source.sql >nul 2>&1"
    if ($LASTEXITCODE -ne 0) { Write-Host "    docker cp failed. Nothing was changed." -ForegroundColor Red; return $false }

    $restoreScript = @"
set -e
sed -i '$stripExpr' /tmp/interim-$Source.sql
cat /tmp/pre-$Source.sql /tmp/interim-$Source.sql /tmp/post-$Source.sql > /tmp/restore-$Source.sql
rm -f /tmp/pre-$Source.sql /tmp/post-$Source.sql
export PGPASSWORD=$dockerPassword
psql -U $dockerUser -d $dockerDb -v ON_ERROR_STOP=on -q --single-transaction -f /tmp/restore-$Source.sql
rm -f /tmp/interim-$Source.sql /tmp/restore-$Source.sql
"@
    # .gitattributes checks .ps1 files out with CRLF, and sh reads the CR as part of
    # each command ("set: line 0: illegal option -"), so the script goes in LF-only.
    docker exec $dockerContainer sh -c ($restoreScript -replace "`r", "")
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    Restore failed - the transaction rolled back, so $Target is unchanged." -ForegroundColor Red
        Write-Host "    If the error names an unrecognized configuration parameter, add it to" -ForegroundColor Yellow
        Write-Host "    `$incompatibleSettings at the top of this script and re-run." -ForegroundColor Yellow
        return $false
    }
    Write-Host "    restored." -ForegroundColor DarkGray
    return $true
}

try {
    $env:PGPASSWORD = $DesktopPassword
    if ($payrollSource -eq $Schema) {
        # PostgresImport wrote both halves into ONE schema: copy it once.
        if ($payrollTarget -ne $SchemaTarget) {
            Write-Host "==> Company and payroll halves share desktop schema '$Schema' but have different" -ForegroundColor Red
            Write-Host "    docker targets ('$SchemaTarget' vs '$payrollTarget'). Use the same name for both." -ForegroundColor Red
            exit 1
        }
        $ok = Sync-Schema -Source $Schema -Target $SchemaTarget
    } else {
        $ok = (Sync-Schema -Source $Schema        -Target $SchemaTarget) -and `
              (Sync-Schema -Source $payrollSource -Target $payrollTarget)
    }
}
finally {
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
}
if (-not $ok) { exit 1 }

Write-Host "`n==> Verifying ..." -ForegroundColor Cyan
docker exec -e PGPASSWORD=$dockerPassword $dockerContainer psql -U $dockerUser -d $dockerDb `
    -c "SELECT '$SchemaTarget' AS company_schema,
               (SELECT count(*) FROM $SchemaTarget.employees)       AS employees,
               (SELECT count(*) FROM $SchemaTarget.employee_alpha)  AS alpha,
               (SELECT count(*) FROM $SchemaTarget.employee_amounts) AS amounts,
               '$payrollTarget' AS payroll_schema,
               (SELECT count(*) FROM $payrollTarget.settings_calendar) AS calendar_periods;"

Write-Host "`n==> Done. Both docker copies now match the desktop import." -ForegroundColor Green
Write-Host "    NOTE: PostgresImport re-mints employees.employeeno on every run, so the" -ForegroundColor Yellow
Write-Host "    'emp-<surrogate>' ids in an EXISTING tenant may no longer line up. A full" -ForegroundColor Yellow
Write-Host "    import resets the tenant first, which makes that a non-issue." -ForegroundColor Yellow
