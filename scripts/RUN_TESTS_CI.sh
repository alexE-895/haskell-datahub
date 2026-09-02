#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# DATAHUB LOCAL CI ISOLATION
#
# The integration suite runs in its own Compose project,
# on dedicated host ports and with dedicated Docker volumes.
# cleanup "down -v" therefore removes CI resources only.
# ============================================================

export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-haskell-datahub-ci}"

export POSTGRES_PUBLISH_PORT="${POSTGRES_PUBLISH_PORT:-15432}"

export CLICKHOUSE_HTTP_PUBLISH_PORT="${CLICKHOUSE_HTTP_PUBLISH_PORT:-18123}"
export CLICKHOUSE_NATIVE_PUBLISH_PORT="${CLICKHOUSE_NATIVE_PUBLISH_PORT:-19000}"

export MINIO_API_PUBLISH_PORT="${MINIO_API_PUBLISH_PORT:-19100}"
export MINIO_CONSOLE_PUBLISH_PORT="${MINIO_CONSOLE_PUBLISH_PORT:-19101}"

export MINIO_CONTAINER_NAME="${MINIO_CONTAINER_NAME:-haskell-datahub-ci-minio-1}"

echo
echo "============================================================"
echo " DATAHUB FULL LINUX INTEGRATION TEST PIPELINE"
echo "============================================================"
echo

COMPOSE_FILES=(
  -f compose.yaml
  -f compose.storage.yaml
)

compose() {
  docker compose "${COMPOSE_FILES[@]}" "$@"
}

BASE_POSTGRES_DB="${POSTGRES_DB:-datahub}"
BASE_CLICKHOUSE_DB="${CLICKHOUSE_DB:-datahub_analytics}"

POSTGRES_TEST_DB="datahub_test"
CLICKHOUSE_TEST_DB="datahub_analytics_test"

POSTGRES_USER="${POSTGRES_USER:-datahub}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-ci_postgres_password}"

CLICKHOUSE_USER="${CLICKHOUSE_USER:-datahub}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-ci_clickhouse_password}"

S3_ACCESS_KEY="${S3_ACCESS_KEY:-datahub}"
S3_SECRET_KEY="${S3_SECRET_KEY:-ci_minio_password}"
S3_BUCKET="${S3_BUCKET:-datahub-files-test}"

# ============================================================
# INFRASTRUCTURE ENVIRONMENT
#
# Export credentials BEFORE docker compose starts.
# This guarantees that the containers are created with the
# same credentials used by readiness checks and integration
# tests below.
# ============================================================

export POSTGRES_DB="$BASE_POSTGRES_DB"
export POSTGRES_USER
export POSTGRES_PASSWORD
export POSTGRES_PORT="$POSTGRES_PUBLISH_PORT"

export CLICKHOUSE_DB="$BASE_CLICKHOUSE_DB"
export CLICKHOUSE_USER
export CLICKHOUSE_PASSWORD

export MINIO_ROOT_USER="$S3_ACCESS_KEY"
export MINIO_ROOT_PASSWORD="$S3_SECRET_KEY"

export S3_ACCESS_KEY
export S3_SECRET_KEY
export S3_BUCKET

cleanup() {

  exit_code=$?

  trap - EXIT
  set +e

  echo
  echo "============================================================"
  echo " CI CLEANUP"
  echo "============================================================"

  if [ "$exit_code" -ne 0 ]; then

    echo
    echo "Integration pipeline failed."
    echo "Collecting Docker diagnostics..."

    compose ps || true

    echo
    echo "===== POSTGRES LOGS ====="
    compose logs \
      --no-color \
      --tail=200 \
      postgres || true

    echo
    echo "===== CLICKHOUSE LOGS ====="
    compose logs \
      --no-color \
      --tail=200 \
      clickhouse || true

    echo
    echo "===== MINIO LOGS ====="
    compose logs \
      --no-color \
      --tail=200 \
      minio || true
  fi

  echo
  echo "Dropping PostgreSQL test database..."

  compose exec -T postgres \
    psql \
    -U "$POSTGRES_USER" \
    -d postgres \
    -c \
    "DROP DATABASE IF EXISTS ${POSTGRES_TEST_DB} WITH (FORCE);" \
    >/dev/null 2>&1 || true

  echo "Dropping ClickHouse test database..."

  compose exec -T clickhouse \
    clickhouse-client \
    --user "$CLICKHOUSE_USER" \
    --password "$CLICKHOUSE_PASSWORD" \
    --query \
    "DROP DATABASE IF EXISTS ${CLICKHOUSE_TEST_DB}" \
    >/dev/null 2>&1 || true

  echo "Stopping CI infrastructure..."

  compose down -v || true

  echo "CI cleanup complete."

  exit "$exit_code"
}

trap cleanup EXIT

# ============================================================
# START INFRASTRUCTURE
# ============================================================

echo "=== START CI INFRASTRUCTURE ==="

compose up \
  -d \
  postgres \
  clickhouse \
  minio

echo
compose ps

# ============================================================
# POSTGRESQL READINESS
# ============================================================

echo
echo "=== WAIT FOR POSTGRESQL ==="

postgres_ready=0

for attempt in $(seq 1 60); do

  if compose exec -T postgres \
      pg_isready \
      -U "$POSTGRES_USER" \
      -d "$BASE_POSTGRES_DB" \
      >/dev/null 2>&1
  then

    postgres_ready=1
    break
  fi

  echo "PostgreSQL not ready: attempt ${attempt}/60"
  sleep 2
done

if [ "$postgres_ready" -ne 1 ]; then
  echo "POSTGRESQL_NOT_READY"
  exit 1
fi

echo "PostgreSQL: READY"

# ============================================================
# CLICKHOUSE READINESS
# ============================================================

echo
echo "=== WAIT FOR CLICKHOUSE ==="

clickhouse_ready=0

for attempt in $(seq 1 60); do

  if compose exec -T clickhouse \
      clickhouse-client \
      --user "$CLICKHOUSE_USER" \
      --password "$CLICKHOUSE_PASSWORD" \
      --query "SELECT 1" \
      >/dev/null 2>&1
  then

    clickhouse_ready=1
    break
  fi

  echo "ClickHouse not ready: attempt ${attempt}/60"
  sleep 2
done

if [ "$clickhouse_ready" -ne 1 ]; then
  echo "CLICKHOUSE_NOT_READY"
  exit 1
fi

echo "ClickHouse: READY"

# ============================================================
# MINIO READINESS
# ============================================================

echo
echo "=== WAIT FOR MINIO ==="

minio_ready=0

for attempt in $(seq 1 60); do

  if curl \
      -fsS \
      "http://127.0.0.1:${MINIO_API_PUBLISH_PORT}/minio/health/live" \
      >/dev/null
  then

    minio_ready=1
    break
  fi

  echo "MinIO not ready: attempt ${attempt}/60"
  sleep 2
done

if [ "$minio_ready" -ne 1 ]; then
  echo "MINIO_NOT_READY"
  exit 1
fi

echo "MinIO: READY"

# ============================================================
# CREATE POSTGRESQL TEST DATABASE
# ============================================================

echo
echo "=== PREPARE POSTGRESQL TEST DATABASE ==="

compose exec -T postgres \
  psql \
  -U "$POSTGRES_USER" \
  -d postgres \
  -v ON_ERROR_STOP=1 \
  -c \
  "DROP DATABASE IF EXISTS ${POSTGRES_TEST_DB} WITH (FORCE);"

compose exec -T postgres \
  psql \
  -U "$POSTGRES_USER" \
  -d postgres \
  -v ON_ERROR_STOP=1 \
  -c \
  "CREATE DATABASE ${POSTGRES_TEST_DB} OWNER ${POSTGRES_USER};"

echo "PostgreSQL test DB: ${POSTGRES_TEST_DB}"

# ============================================================
# CREATE CLICKHOUSE TEST DATABASE
# ============================================================

echo
echo "=== PREPARE CLICKHOUSE TEST DATABASE ==="

compose exec -T clickhouse \
  clickhouse-client \
  --user "$CLICKHOUSE_USER" \
  --password "$CLICKHOUSE_PASSWORD" \
  --query \
  "DROP DATABASE IF EXISTS ${CLICKHOUSE_TEST_DB}"

compose exec -T clickhouse \
  clickhouse-client \
  --user "$CLICKHOUSE_USER" \
  --password "$CLICKHOUSE_PASSWORD" \
  --query \
  "CREATE DATABASE ${CLICKHOUSE_TEST_DB}"

echo "ClickHouse test DB: ${CLICKHOUSE_TEST_DB}"

# ============================================================
# TEST ENVIRONMENT
# ============================================================

export POSTGRES_HOST="127.0.0.1"
export POSTGRES_PORT="$POSTGRES_PUBLISH_PORT"
export POSTGRES_DB="$POSTGRES_TEST_DB"
export POSTGRES_USER="$POSTGRES_USER"
export POSTGRES_PASSWORD="$POSTGRES_PASSWORD"

export CLICKHOUSE_HOST="127.0.0.1"
export CLICKHOUSE_PORT="$CLICKHOUSE_HTTP_PUBLISH_PORT"
export CLICKHOUSE_DB="$CLICKHOUSE_TEST_DB"
export CLICKHOUSE_USER="$CLICKHOUSE_USER"
export CLICKHOUSE_PASSWORD="$CLICKHOUSE_PASSWORD"

export S3_HOST="127.0.0.1"
export S3_PORT="$MINIO_API_PUBLISH_PORT"
export S3_SECURE="false"
export S3_ACCESS_KEY="$S3_ACCESS_KEY"
export S3_SECRET_KEY="$S3_SECRET_KEY"
export S3_BUCKET="$S3_BUCKET"

echo
echo "PostgreSQL DB : $POSTGRES_DB"
echo "ClickHouse DB : $CLICKHOUSE_DB"
echo "S3 bucket     : $S3_BUCKET"

# ============================================================
# CABAL PACKAGE INDEX
# ============================================================

echo
echo "=== CABAL UPDATE ==="

cabal update

# ============================================================
# POSTGRESQL MIGRATIONS
# ============================================================

echo
echo "=== POSTGRESQL MIGRATIONS ==="

cabal run \
  exe:haskell-datahub \
  -- \
  migrate

echo "POSTGRESQL MIGRATIONS: PASS"

# ============================================================
# CLICKHOUSE MIGRATIONS
# ============================================================

echo
echo "=== CLICKHOUSE MIGRATIONS ==="

cabal run \
  exe:haskell-datahub \
  -- \
  clickhouse-migrate

echo "CLICKHOUSE MIGRATIONS: PASS"

# ============================================================
# HASKELL INTEGRATION TESTS
# ============================================================

echo
echo "============================================================"
echo " HASKELL INTEGRATION TEST SUITE"
echo "============================================================"

cabal test \
  haskell-datahub-test \
  --test-show-details=direct

echo
echo "HASKELL INTEGRATION TEST SUITE: PASS"

# ============================================================
# VERIFY TRANSACTIONAL OUTBOX
# ============================================================

echo
echo "=== VERIFY TRANSACTIONAL OUTBOX ==="

OUTBOX_COUNT="$(
  compose exec -T postgres \
    psql \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_TEST_DB" \
    -t \
    -A \
    -v ON_ERROR_STOP=1 \
    -c \
    "SELECT count(*) FROM analytics_outbox;" |
  tr -d '[:space:]'
)"

echo "Outbox events: $OUTBOX_COUNT"

if [ "$OUTBOX_COUNT" -lt 1 ]; then
  echo "NO_OUTBOX_EVENTS_CREATED"
  exit 1
fi

# ============================================================
# VERIFY CLICKHOUSE EVENTS
# ============================================================

echo
echo "=== VERIFY CLICKHOUSE EVENTS ==="

CLICKHOUSE_COUNT="$(
  compose exec -T clickhouse \
    clickhouse-client \
    --user "$CLICKHOUSE_USER" \
    --password "$CLICKHOUSE_PASSWORD" \
    --database "$CLICKHOUSE_TEST_DB" \
    --query \
    "SELECT count() FROM analytics_events" |
  tr -d '[:space:]'
)"

echo "ClickHouse events: $CLICKHOUSE_COUNT"

if [ "$CLICKHOUSE_COUNT" -lt 1 ]; then
  echo "CLICKHOUSE_ANALYTICS_EVENTS_EMPTY"
  exit 1
fi

# ============================================================
# CRASH / REPLAY IDEMPOTENCY
# ============================================================

echo
echo "============================================================"
echo " OUTBOX CRASH / REPLAY IDEMPOTENCY"
echo "============================================================"

echo "Simulating worker crash after ClickHouse insert..."

compose exec -T postgres \
  psql \
  -U "$POSTGRES_USER" \
  -d "$POSTGRES_TEST_DB" \
  -v ON_ERROR_STOP=1 \
  -c "
UPDATE analytics_outbox
SET
    processed_at = NULL,
    locked_at = NULL,
    locked_by = NULL,
    next_attempt_at = NOW();
"

echo
echo "Replaying analytics events..."

cabal run \
  exe:haskell-datahub \
  -- \
  analytics-flush

# ============================================================
# DUPLICATE EVENT CHECK
# ============================================================

echo
echo "=== VERIFY EVENT IDEMPOTENCY ==="

DUPLICATE_COUNT="$(
  compose exec -T clickhouse \
    clickhouse-client \
    --user "$CLICKHOUSE_USER" \
    --password "$CLICKHOUSE_PASSWORD" \
    --database "$CLICKHOUSE_TEST_DB" \
    --query "
SELECT count()
FROM
(
    SELECT event_id
    FROM analytics_events
    GROUP BY event_id
    HAVING count() > 1
)
" |
  tr -d '[:space:]'
)"

echo "Duplicate event IDs: $DUPLICATE_COUNT"

if [ "$DUPLICATE_COUNT" != "0" ]; then
  echo "EVENT_IDEMPOTENCY_FAILED"
  exit 1
fi

# ============================================================
# OUTBOX MUST BE FULLY PROCESSED
# ============================================================

echo
echo "=== VERIFY OUTBOX COMPLETION ==="

PENDING_COUNT="$(
  compose exec -T postgres \
    psql \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_TEST_DB" \
    -t \
    -A \
    -v ON_ERROR_STOP=1 \
    -c \
    "SELECT count(*) FROM analytics_outbox WHERE processed_at IS NULL;" |
  tr -d '[:space:]'
)"

echo "Pending outbox events: $PENDING_COUNT"

if [ "$PENDING_COUNT" != "0" ]; then
  echo "OUTBOX_REPLAY_INCOMPLETE"
  exit 1
fi

# ============================================================
# FINAL
# ============================================================

echo
echo "============================================================"
echo " FULL LINUX INTEGRATION CI: PASS"
echo "============================================================"
echo "PostgreSQL readiness       : PASS"
echo "ClickHouse readiness       : PASS"
echo "MinIO readiness            : PASS"
echo "PostgreSQL migrations      : PASS"
echo "ClickHouse migrations      : PASS"
echo "Haskell integration tests  : PASS"
echo "Transactional outbox       : PASS"
echo "ClickHouse analytics       : PASS"
echo "Replay idempotency         : PASS"
echo "Pending outbox             : 0"
echo "============================================================"