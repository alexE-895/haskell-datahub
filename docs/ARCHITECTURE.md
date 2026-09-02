# Architecture

## Overview

Haskell DataHub is split into an HTTP API, PostgreSQL-backed domain services, background workers, ClickHouse analytics, external API integration and S3-compatible object storage.

```text
Clients
   |
   v
Servant API
   |
   +------------------+
   |                  |
   v                  v
Service layer       Health / metrics
   |
   v
Repository layer
   |
   v
PostgreSQL
   |
   +-------- transactional outbox --------+
                                          |
                                          v
                                  Analytics worker
                                          |
                                          v
                                      ClickHouse
```

External synchronization:

```text
Client
  |
  v
POST /sync/github
  |
  v
PostgreSQL sync job
  |
  v
Sync worker
  |
  v
GitHub API
  |
  v
PostgreSQL items
```

File storage:

```text
Client
  |
  v
Servant API
  |
  v
Storage service
  |
  +------ metadata ------> PostgreSQL
  |
  +------ object --------> MinIO / S3
```

## Layers

### API

`DataHub.API` defines the Servant API at the type level.

### Server

`DataHub.Server` owns Servant handlers, HTTP error mapping, uniform JSON errors, health/readiness and dependency wiring.

### Service layer

Examples: `DataHub.Service.Category`, `DataHub.Service.Item`, `DataHub.Sync.Service`, `DataHub.Storage.Service`.

Responsibilities: validation, domain rules, state transitions and orchestration.

### Repository layer

Examples: `DataHub.Repository.Category`, `DataHub.Repository.Item`, `DataHub.Sync.Repository`, `DataHub.Storage.Repository`.

Responsibilities: SQL, persistence and transactional state transitions.

### Database

`DataHub.Database` owns PostgreSQL configuration, connection pool creation, readiness checks and controlled pool lifecycle. `withDatabasePool` uses exception-safe resource management.

## PostgreSQL

PostgreSQL is the source of truth for categories, items, analytics outbox, sync jobs and stored-file metadata.

Schema evolution uses ordered SQL migrations. The project includes relational constraints, hierarchical data, recursive hierarchy checks, indexes, transactional outbox state, retry metadata and keyset pagination.

## Analytics architecture

Business writes do not depend directly on ClickHouse availability. Analytics uses the transactional outbox pattern: a business transaction writes an event into PostgreSQL, then a worker later delivers it to ClickHouse. This makes analytics eventually consistent while keeping the core API available during ClickHouse outages.

Replay is idempotent through `event_id`.

## ClickHouse

The main table uses MergeTree, monthly `toYYYYMM(event_time)` partitioning, sorting by `(entity_type, event_type, event_time, entity_id)`, 365-day TTL and a Bloom data-skipping index on `event_id`.

The base sorting key was kept because benchmarks showed it performs well for the existing entity/event/time analytics workload.

## Workers

Two long-running workers exist:

- analytics worker: PostgreSQL outbox -> ClickHouse
- sync worker: PostgreSQL sync jobs -> GitHub API -> PostgreSQL items

Both use database claims so ownership of work is persisted.

## Object storage

MinIO provides S3-compatible object storage. PostgreSQL stores metadata and lifecycle states, while MinIO stores the actual bytes.

## Observability

HTTP middleware records structured request information including timestamp, request ID, method, path, status and duration. Prometheus exposes metrics and Grafana can visualize them.

## Runtime configuration

`DataHub.Config` separates development, test and production. Production requires sensitive values explicitly and invalid configuration fails during startup.

## Resource lifecycle

PostgreSQL connection pools are scoped with `bracket` semantics:

```text
acquire -> use -> release
```

This applies to the API, migrations and workers.

## Containers and Kubernetes

The application Docker image uses a multi-stage build and executes as a non-root user.

Kubernetes manifests include API deployment, PostgreSQL/ClickHouse/MinIO StatefulSets, migration Jobs, workers, ConfigMap/Secret references, probes, resources, PDB and NetworkPolicies.

## Reproducibility and CI

Nix defines the Haskell environment. The full Linux integration pipeline creates isolated PostgreSQL, ClickHouse and MinIO infrastructure, applies migrations, runs Haskell tests, verifies outbox replay/idempotency and cleans up isolated resources afterward.