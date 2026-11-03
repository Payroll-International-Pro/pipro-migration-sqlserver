@echo off
rem ===========================================================================
rem  reset_tenant.cmd - DELETES every trace of a previous legacy import from one
rem  tenant on the docker (experimental) Postgres, so the next import starts
rem  from scratch.
rem
rem  Runs sql\09_reset_tenant.sql, which:
rem     - empties every employee- and run-scoped table in the tenant schema
rem       (employees, amounts, dates, history, payroll periods, payslips, the
rem       carried legacy settings, held master-file changes ...)
rem     - removes the client's imported legacy calc program (calc_program
rem       'legacy:*' rows)
rem     - removes the login users the import minted for this tenant's employees
rem       (public.pipro_core_users), and this tenant's migration staging rows
rem  and KEEPS the eight configuration tables provisioning created (payrolls,
rem  leave types, holidays, code catalogue, payslip settings, the module
rem  migration ledger, the country pack's own calc program).
rem
rem  Other tenants are not touched.
rem
rem  Usage:   reset_tenant.cmd                  (TENANT_SCHEMA from settings.local.txt)
rem           reset_tenant.cmd tenant_acme
rem
rem  NOT REVERSIBLE. You must type RESET to proceed.
rem ===========================================================================
setlocal
cd /d "%~dp0"

if not exist "settings.local.txt" (
    echo.
    echo     No settings.local.txt found in this folder.
    echo     Copy settings.example.txt to settings.local.txt and fill it in.
    goto :failed
)
for /f "usebackq eol=# tokens=1,* delims==" %%a in ("settings.local.txt") do set "%%a=%%b"

set TENANT=%~1
if not defined TENANT set TENANT=%TENANT_SCHEMA%
if not defined TENANT (
    echo     No tenant given and settings.local.txt has no TENANT_SCHEMA.
    goto :failed
)

docker info >nul 2>&1
if errorlevel 1 (
    echo     Docker is not running. Start Docker Desktop and re-run.
    goto :failed
)

echo.
echo ===========================================================================
echo  RESET   %TENANT%   on docker %DOCKER_CONTAINER% / %DOCKER_DB%
echo.
echo  Deletes all imported and run-generated data in this tenant, its imported
echo  legacy calc program, and the login users minted for its employees.
echo  Configuration is kept. Other tenants are untouched. NOT REVERSIBLE.
echo ===========================================================================
echo.
set /p CONFIRM="Type RESET to delete everything listed above: "
if not "%CONFIRM%"=="RESET" (
    echo     Not confirmed. Nothing was changed.
    goto :done
)

type sql\09_reset_tenant.sql | docker exec -i -e PGPASSWORD=%DOCKER_PASSWORD% %DOCKER_CONTAINER% psql -U %DOCKER_USER% -d %DOCKER_DB% -v ON_ERROR_STOP=on -v tenant_schema=%TENANT% -v confirm=RESET
if errorlevel 1 goto :failed

:done
echo.
pause
exit /b 0

:failed
echo.
echo ===========================================================================
echo  FAILED. The reset runs as one statement block, so nothing was half-done.
echo ===========================================================================
pause
exit /b 1
