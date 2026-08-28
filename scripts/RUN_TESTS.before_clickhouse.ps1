$ErrorActionPreference = "Stop"

$ProjectRoot =
    Split-Path -Parent $PSScriptRoot

Set-Location $ProjectRoot

$RequiredPaths = @(
    "C:\ghcup\msys64\mingw64\opt\pg-16\bin",
    "C:\ghcup\msys64\mingw64\bin"
)

foreach ($RequiredPath in $RequiredPaths) {
    if (($env:Path -split ";") -notcontains $RequiredPath) {
        $env:Path = "$RequiredPath;$env:Path"
    }
}

Write-Host "=== DATAHUB INTEGRATION TESTS ==="
Write-Host ""

docker compose up -d postgres

if ($LASTEXITCODE -ne 0) {
    throw "POSTGRES_START_FAILED"
}

Write-Host "Waiting for PostgreSQL..."

$Healthy = $false

for ($Attempt = 1; $Attempt -le 30; $Attempt++) {

    docker compose exec -T postgres `
        pg_isready `
        -U datahub `
        -d datahub *> $null

    if ($LASTEXITCODE -eq 0) {
        $Healthy = $true
        break
    }

    Start-Sleep -Seconds 1
}

if (-not $Healthy) {
    throw "POSTGRES_NOT_READY"
}

Write-Host "PostgreSQL ready."

docker compose exec -T postgres `
    dropdb `
    -U datahub `
    --if-exists `
    --force `
    datahub_test

if ($LASTEXITCODE -ne 0) {
    throw "TEST_DATABASE_DROP_FAILED"
}

docker compose exec -T postgres `
    createdb `
    -U datahub `
    -O datahub `
    datahub_test

if ($LASTEXITCODE -ne 0) {
    throw "TEST_DATABASE_CREATE_FAILED"
}

$OldPostgresDb = $env:POSTGRES_DB

try {
    $env:POSTGRES_DB = "datahub_test"

    Write-Host ""
    Write-Host "=== MIGRATIONS ==="

    cabal run haskell-datahub -- migrate

    if ($LASTEXITCODE -ne 0) {
        throw "TEST_MIGRATIONS_FAILED"
    }

    Write-Host ""
    Write-Host "=== HASKELL TEST SUITE ==="

    cabal test haskell-datahub-test `
        --test-show-details=direct

    if ($LASTEXITCODE -ne 0) {
        throw "HASKELL_TESTS_FAILED"
    }
}
finally {

    if ($null -eq $OldPostgresDb) {
        Remove-Item Env:POSTGRES_DB `
            -ErrorAction SilentlyContinue
    }
    else {
        $env:POSTGRES_DB = $OldPostgresDb
    }

    Write-Host ""
    Write-Host "Cleaning test database..."

    docker compose exec -T postgres `
        dropdb `
        -U datahub `
        --if-exists `
        --force `
        datahub_test
}

Write-Host ""
Write-Host "ALL TESTS PASSED"