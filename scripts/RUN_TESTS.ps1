$ErrorActionPreference = "Continue"

$ProjectRoot = "C:\Users\Alex\Desktop\HASKELL\PROJECTS\haskell-datahub"
$ComposeFile = Join-Path $ProjectRoot "compose.yaml"

Set-Location $ProjectRoot

Write-Host ""
Write-Host "============================================================"
Write-Host " DATAHUB FULL INTEGRATION TEST PIPELINE"
Write-Host "============================================================"
Write-Host ""

# Native PostgreSQL libraries required by postgresql-simple.
$env:Path =
    "C:\ghcup\msys64\mingw64\opt\pg-16\bin;" +
    "C:\ghcup\msys64\mingw64\bin;" +
    $env:Path

$PostgresTestDb  = "datahub_test"
$ClickHouseTestDb = "datahub_analytics_test"

$ClickHouseUser =
    if ($env:CLICKHOUSE_USER) {
        $env:CLICKHOUSE_USER
    }
    else {
        "datahub"
    }

$ClickHousePassword =
    if ($env:CLICKHOUSE_PASSWORD) {
        $env:CLICKHOUSE_PASSWORD
    }
    else {
        "datahub_clickhouse_dev_password"
    }

# Preserve caller environment.
$OldPostgresDb = $env:POSTGRES_DB

$OldClickHouseHost = $env:CLICKHOUSE_HOST
$OldClickHousePort = $env:CLICKHOUSE_PORT
$OldClickHouseDb = $env:CLICKHOUSE_DB
$OldClickHouseUser = $env:CLICKHOUSE_USER
$OldClickHousePassword = $env:CLICKHOUSE_PASSWORD

function Assert-NativeSuccess {
    param(
        [string]$Label
    )

    if ($LASTEXITCODE -ne 0) {
        throw "$Label FAILED exit_code=$LASTEXITCODE"
    }
}

function Restore-EnvironmentVariable {
    param(
        [string]$Name,

        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        Remove-Item "Env:$Name" `
            -ErrorAction SilentlyContinue
    }
    else {
        Set-Item "Env:$Name" $Value
    }
}

try {

    # ========================================================
    # INFRASTRUCTURE
    # ========================================================

    Write-Host "=== START INFRASTRUCTURE ==="

    & docker compose `
        -f $ComposeFile `
        up -d postgres clickhouse

    Assert-NativeSuccess "docker compose up"

    # ========================================================
    # POSTGRESQL READINESS
    # ========================================================

    Write-Host ""
    Write-Host "Waiting for PostgreSQL..."

    $PostgresReady = $false

    for ($Attempt = 1; $Attempt -le 60; $Attempt++) {

        $null = & docker compose `
            -f $ComposeFile `
            exec -T postgres `
            pg_isready `
            -U datahub `
            -d datahub `
            2>&1

        $NativeExitCode = $LASTEXITCODE

        if ($NativeExitCode -eq 0) {
            $PostgresReady = $true
            break
        }

        Start-Sleep -Seconds 1
    }

    if (-not $PostgresReady) {
        throw "POSTGRESQL_NOT_READY"
    }

    Write-Host "PostgreSQL: READY"

    # ========================================================
    # CLICKHOUSE READINESS
    # ========================================================

    Write-Host ""
    Write-Host "Waiting for ClickHouse..."

    $ClickHouseReady = $false

    for ($Attempt = 1; $Attempt -le 60; $Attempt++) {

        $null = & docker compose `
            -f $ComposeFile `
            exec -T clickhouse `
            clickhouse-client `
            --user $ClickHouseUser `
            --password $ClickHousePassword `
            --query "SELECT 1" `
            2>&1

        $NativeExitCode = $LASTEXITCODE

        if ($NativeExitCode -eq 0) {
            $ClickHouseReady = $true
            break
        }

        Start-Sleep -Seconds 1
    }

    if (-not $ClickHouseReady) {
        throw "CLICKHOUSE_NOT_READY"
    }

    Write-Host "ClickHouse: READY"

    # ========================================================
    # CLEAN POSTGRES TEST DATABASE
    # ========================================================

    Write-Host ""
    Write-Host "=== PREPARE POSTGRESQL TEST DATABASE ==="

    & docker compose `
        -f $ComposeFile `
        exec -T postgres `
        psql `
        -U datahub `
        -d postgres `
        -v ON_ERROR_STOP=1 `
        -c "DROP DATABASE IF EXISTS $PostgresTestDb WITH (FORCE);"

    Assert-NativeSuccess "Drop PostgreSQL test database"

    & docker compose `
        -f $ComposeFile `
        exec -T postgres `
        psql `
        -U datahub `
        -d postgres `
        -v ON_ERROR_STOP=1 `
        -c "CREATE DATABASE $PostgresTestDb OWNER datahub;"

    Assert-NativeSuccess "Create PostgreSQL test database"

    # ========================================================
    # CLEAN CLICKHOUSE TEST DATABASE
    # ========================================================

    Write-Host ""
    Write-Host "=== PREPARE CLICKHOUSE TEST DATABASE ==="

    & docker compose `
        -f $ComposeFile `
        exec -T clickhouse `
        clickhouse-client `
        --user $ClickHouseUser `
        --password $ClickHousePassword `
        --query "DROP DATABASE IF EXISTS $ClickHouseTestDb"

    Assert-NativeSuccess "Drop ClickHouse test database"

    & docker compose `
        -f $ComposeFile `
        exec -T clickhouse `
        clickhouse-client `
        --user $ClickHouseUser `
        --password $ClickHousePassword `
        --query "CREATE DATABASE $ClickHouseTestDb"

    Assert-NativeSuccess "Create ClickHouse test database"

    # ========================================================
    # ISOLATED TEST ENVIRONMENT
    # ========================================================

    $env:POSTGRES_DB = $PostgresTestDb

    $env:CLICKHOUSE_HOST = "127.0.0.1"
    $env:CLICKHOUSE_PORT = "8123"
    $env:CLICKHOUSE_DB = $ClickHouseTestDb
    $env:CLICKHOUSE_USER = $ClickHouseUser
    $env:CLICKHOUSE_PASSWORD = $ClickHousePassword

    Write-Host ""
    Write-Host "PostgreSQL test DB : $PostgresTestDb"
    Write-Host "ClickHouse test DB : $ClickHouseTestDb"

    # ========================================================
    # POSTGRESQL MIGRATIONS
    # ========================================================

    Write-Host ""
    Write-Host "=== POSTGRESQL MIGRATIONS ==="

    & cabal run haskell-datahub -- migrate

    Assert-NativeSuccess "PostgreSQL migrations"

    # ========================================================
    # CLICKHOUSE MIGRATIONS
    # ========================================================

    Write-Host ""
    Write-Host "=== CLICKHOUSE MIGRATIONS ==="

    & cabal run haskell-datahub -- clickhouse-migrate

    Assert-NativeSuccess "ClickHouse migrations"

    # ========================================================
    # HASKELL INTEGRATION TESTS
    # ========================================================

    Write-Host ""
    Write-Host "=== HASKELL TEST SUITE ==="

    & cabal test haskell-datahub-test `
        --test-show-details=direct

    Assert-NativeSuccess "Haskell test suite"

    # ========================================================
    # VERIFY OUTBOX EXISTS
    # ========================================================

    Write-Host ""
    Write-Host "=== VERIFY TRANSACTIONAL OUTBOX ==="

    $OutboxCount = (
        & docker compose `
            -f $ComposeFile `
            exec -T postgres `
            psql `
            -U datahub `
            -d $PostgresTestDb `
            -t `
            -A `
            -v ON_ERROR_STOP=1 `
            -c "
SELECT count(*)
FROM analytics_outbox;
"
    ).Trim()

    Assert-NativeSuccess "Read analytics_outbox"

    Write-Host "Outbox events: $OutboxCount"

    if ([int]$OutboxCount -lt 1) {
        throw "NO_OUTBOX_EVENTS_CREATED"
    }

    # ========================================================
    # VERIFY CLICKHOUSE RECEIVED EVENTS
    # ========================================================

    Write-Host ""
    Write-Host "=== VERIFY CLICKHOUSE EVENTS ==="

    $ClickHouseCount = (
        & docker compose `
            -f $ComposeFile `
            exec -T clickhouse `
            clickhouse-client `
            --user $ClickHouseUser `
            --password $ClickHousePassword `
            --database $ClickHouseTestDb `
            --query "
SELECT count()
FROM analytics_events
"
    ).Trim()

    Assert-NativeSuccess "Read ClickHouse analytics_events"

    Write-Host "ClickHouse events: $ClickHouseCount"

    if ([int]$ClickHouseCount -lt 1) {
        throw "CLICKHOUSE_ANALYTICS_EVENTS_EMPTY"
    }

    # ========================================================
    # CRASH / REPLAY IDEMPOTENCY TEST
    # ========================================================

    Write-Host ""
    Write-Host "=== OUTBOX IDEMPOTENCY REPLAY ==="

    Write-Host "Simulating worker crash after ClickHouse insert..."

    # Pretend ClickHouse accepted the events, but the worker crashed
    # before PostgreSQL processed_at was committed.
    & docker compose `
        -f $ComposeFile `
        exec -T postgres `
        psql `
        -U datahub `
        -d $PostgresTestDb `
        -v ON_ERROR_STOP=1 `
        -c "
UPDATE analytics_outbox
SET
    processed_at = NULL,
    locked_at = NULL,
    locked_by = NULL,
    next_attempt_at = NOW();
"

    Assert-NativeSuccess "Reset outbox for replay"

    Write-Host "Replaying events..."

    & cabal run haskell-datahub -- analytics-flush

    Assert-NativeSuccess "Analytics replay"

    # ========================================================
    # DUPLICATE CHECK
    # ========================================================

    $DuplicateCount = (
        & docker compose `
            -f $ComposeFile `
            exec -T clickhouse `
            clickhouse-client `
            --user $ClickHouseUser `
            --password $ClickHousePassword `
            --database $ClickHouseTestDb `
            --query "
SELECT count()
FROM
(
    SELECT event_id
    FROM analytics_events
    GROUP BY event_id
    HAVING count() > 1
)
"
    ).Trim()

    Assert-NativeSuccess "Check duplicate event ids"

    Write-Host "Duplicate event IDs: $DuplicateCount"

    if ($DuplicateCount -ne "0") {
        throw "EVENT_IDEMPOTENCY_FAILED duplicates=$DuplicateCount"
    }

    # ========================================================
    # OUTBOX MUST BE PROCESSED AGAIN
    # ========================================================

    $PendingCount = (
        & docker compose `
            -f $ComposeFile `
            exec -T postgres `
            psql `
            -U datahub `
            -d $PostgresTestDb `
            -t `
            -A `
            -v ON_ERROR_STOP=1 `
            -c "
SELECT count(*)
FROM analytics_outbox
WHERE processed_at IS NULL;
"
    ).Trim()

    Assert-NativeSuccess "Check pending outbox"

    Write-Host "Pending outbox events: $PendingCount"

    if ($PendingCount -ne "0") {
        throw "OUTBOX_REPLAY_INCOMPLETE pending=$PendingCount"
    }

    # ========================================================
    # FINAL RESULT
    # ========================================================

    Write-Host ""
    Write-Host "============================================================"
    Write-Host " ALL FULL-STACK INTEGRATION TESTS PASSED"
    Write-Host "============================================================"
    Write-Host "PostgreSQL migrations         : PASS"
    Write-Host "ClickHouse migrations         : PASS"
    Write-Host "Category API                  : PASS"
    Write-Host "Item API                      : PASS"
    Write-Host "Search/filter/pagination      : PASS"
    Write-Host "Transactional outbox          : PASS"
    Write-Host "Analytics worker              : PASS"
    Write-Host "Analytics API                 : PASS"
    Write-Host "Analytics degradation         : PASS"
    Write-Host "Event replay idempotency      : PASS"
    Write-Host "============================================================"
}
finally {

    Write-Host ""
    Write-Host "=== CLEANUP ==="

    Restore-EnvironmentVariable `
        "POSTGRES_DB" `
        $OldPostgresDb

    Restore-EnvironmentVariable `
        "CLICKHOUSE_HOST" `
        $OldClickHouseHost

    Restore-EnvironmentVariable `
        "CLICKHOUSE_PORT" `
        $OldClickHousePort

    Restore-EnvironmentVariable `
        "CLICKHOUSE_DB" `
        $OldClickHouseDb

    Restore-EnvironmentVariable `
        "CLICKHOUSE_USER" `
        $OldClickHouseUser

    Restore-EnvironmentVariable `
        "CLICKHOUSE_PASSWORD" `
        $OldClickHousePassword

    Write-Host "Dropping PostgreSQL test database..."

    $CleanupOutput = & docker compose `
        -f $ComposeFile `
        exec -T postgres `
        psql `
        -U datahub `
        -d postgres `
        -c "DROP DATABASE IF EXISTS $PostgresTestDb WITH (FORCE);" `
        2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "PostgreSQL cleanup warning:"
        $CleanupOutput | ForEach-Object {
            Write-Host $_
        }
    }

    Write-Host "Dropping ClickHouse test database..."

    $CleanupOutput = & docker compose `
        -f $ComposeFile `
        exec -T clickhouse `
        clickhouse-client `
        --user $ClickHouseUser `
        --password $ClickHousePassword `
        --query "DROP DATABASE IF EXISTS $ClickHouseTestDb" `
        2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "ClickHouse cleanup warning:"
        $CleanupOutput | ForEach-Object {
            Write-Host $_
        }
    }

    Write-Host "Test environment cleaned."
}