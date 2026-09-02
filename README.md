# Haskell DataHub

Production-style backend service written in Haskell.

The project demonstrates a complete backend workflow rather than an isolated CRUD example: typed REST APIs, PostgreSQL persistence, ClickHouse analytics, background workers, external API integration, S3-compatible storage, observability, Docker, Kubernetes, Nix and CI.

## Stack

- Haskell / GHC 9.10.3 / GHC2024
- Cabal
- Servant
- PostgreSQL 16
- ClickHouse 25.8
- MinIO / S3-compatible storage
- Prometheus / Grafana
- Docker / Docker Compose
- Kubernetes
- Nix flakes
- GitHub Actions

## Main capabilities

### Categories

Hierarchical category CRUD with parent/child relationships, duplicate sibling protection, cycle detection and protected deletion of non-leaf categories.

### Items

Item CRUD with PostgreSQL persistence, category validation, search, source filtering, offset pagination and keyset pagination with `afterId`.

### Analytics

Transactional analytics pipeline:

1. Business transaction writes to PostgreSQL.
2. Analytics event is inserted into a transactional outbox.
3. Background worker claims pending events.
4. Events are delivered to ClickHouse.
5. Processed state is persisted.
6. Replay is idempotent by `event_id`.

ClickHouse uses MergeTree, monthly partitioning, LowCardinality columns, 365-day TTL and an event-id Bloom data-skipping index.

### External synchronization

GitHub synchronization runs as a background job. The API creates a job, while a worker claims it, calls the GitHub REST API, imports repositories and records success or failure.

### Object storage

Files are stored in MinIO through an S3-compatible API. PostgreSQL keeps metadata and lifecycle state while MinIO stores object bytes.

### Observability

The API provides:

- `/health`
- `/ready`
- Prometheus metrics
- structured HTTP request logs
- request IDs
- request duration and status tracking

## REST API

Health:

```text
GET /health
GET /ready
```

Categories:

```text
GET    /categories
GET    /categories/:categoryId
POST   /categories
PATCH  /categories/:categoryId
DELETE /categories/:categoryId
```

Items:

```text
GET    /items
GET    /items/:itemId
POST   /items
PATCH  /items/:itemId
DELETE /items/:itemId
```

Item list query parameters include `search`, `categoryId`, `source`, `limit`, `offset` and `afterId`.

GitHub synchronization:

```text
POST /sync/github
GET  /sync/jobs/:jobId
```

Files:

```text
POST   /files
GET    /files/:fileId
GET    /files/:fileId/download
DELETE /files/:fileId
```

Analytics:

```text
GET /analytics/events/summary
GET /analytics/items/by-source
```

## CLI modes

```text
haskell-datahub serve
haskell-datahub migrate
haskell-datahub clickhouse-migrate
haskell-datahub analytics-flush
haskell-datahub analytics-worker
haskell-datahub sync-flush
haskell-datahub sync-worker
haskell-datahub storage-init
haskell-datahub storage-smoke
```

Running without arguments starts the API server.

## Configuration

Runtime modes:

```text
DATAHUB_ENV=development
DATAHUB_ENV=test
DATAHUB_ENV=production
```

Production mode requires sensitive credentials explicitly. Important variables include PostgreSQL, ClickHouse, S3/MinIO and GitHub settings. Do not commit real credentials. See `.env.example`.

## Nix development shell

Inside Ubuntu / WSL:

```bash
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
nix develop
```

Build:

```bash
cabal build
```

## Migrations

PostgreSQL:

```bash
cabal run exe:haskell-datahub -- migrate
```

ClickHouse:

```bash
cabal run exe:haskell-datahub -- clickhouse-migrate
```

## Tests

The integration suite covers health/readiness, categories, items, pagination, transactional outbox, ClickHouse delivery, replay idempotency, external sync and storage lifecycle.

```bash
bash scripts/RUN_TESTS_CI.sh
```

## Docker

```bash
docker build -t haskell-datahub:dev .
```

The runtime image executes as a non-root user.

## Kubernetes

Base manifests are under `k8s/base`.

Hardening includes non-root application workloads, dropped capabilities, RuntimeDefault seccomp, read-only root filesystems, disabled automatic service-account tokens, resource requests/limits, probes, PodDisruptionBudget and NetworkPolicy rules.

## Performance work

### PostgreSQL

Item search was benchmarked and optimized with trigram indexes, source indexing and keyset pagination. Deep pagination benchmarks showed a major advantage for keyset pagination over large OFFSET values.

### ClickHouse

Optimization used `EXPLAIN indexes = 1`, `system.query_log`, `read_rows`, `read_bytes`, latency and storage overhead. For event-id lookup, a Bloom filter produced the best measured trade-off and was selected instead of a projection.

## Architecture

See `docs/ARCHITECTURE.md`.

## Engineering trade-offs

See `docs/TRADEOFFS.md`.

## License

MIT.