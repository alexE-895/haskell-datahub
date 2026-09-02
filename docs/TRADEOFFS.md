# Engineering Trade-offs

This document records deliberate technical decisions and their costs.

## PostgreSQL as source of truth

PostgreSQL owns transactional application state. ClickHouse is used for analytics rather than OLTP because relational constraints and multi-step business transactions belong in PostgreSQL.

## Transactional outbox

Analytics delivery is asynchronous through PostgreSQL instead of directly writing to PostgreSQL and ClickHouse in one request.

Benefits:

- ClickHouse outages do not make the core API unavailable
- event delivery state is durable
- replay can be controlled

Cost: analytics is eventually consistent.

## ClickHouse sorting key

The sorting key remains `(entity_type, event_type, event_time, entity_id)` because benchmarks showed strong skipping for the existing entity/event/time workload. Reordering it for one query could make other important queries worse.

## Event-id Bloom filter

Event-id lookup was benchmarked with the baseline table, a Bloom data-skipping index and a projection ordered by event ID. Bloom was selected because it reduced rows read substantially with lower storage overhead than the projection.

Bloom is an optimization, not a uniqueness constraint.

## Aggregate materialized views

Summary queries can scan large portions of ClickHouse. Aggregate materialized views were considered but not added because measured latency at the current dataset size remained low. They would add storage, write amplification, migration complexity and retention concerns.

## OFFSET and keyset pagination

OFFSET remains available for simple navigation. `afterId` keyset pagination is preferable for deep traversal because it avoids increasingly expensive large offsets.

Trade-off: keyset pagination is not designed for arbitrary page-number jumps.

## File upload implementation

The current API accepts bounded request bodies and uses temporary files before S3 upload. The application limit is 10 MiB.

For much larger objects, streaming or pre-signed multipart uploads would be a better design.

## PostgreSQL pool size

The project uses a small fixed pool suitable for the current environment. Real production sizing should consider replica count, PostgreSQL connection limits, concurrency and query latency.

## Worker model

Workers use PostgreSQL polling/claiming instead of Kafka or another broker. This keeps the architecture smaller and preserves transactional work state in PostgreSQL. Very high throughput workloads may justify a dedicated queue or event stream later.

## GitHub integration

External calls have a finite timeout and failed jobs are persisted. Advanced rate-limit scheduling, circuit breakers and distributed rate-limit coordination are future options, not claimed as implemented.

## Secrets

Development/test may use local defaults. Production requires explicit sensitive credentials. Kubernetes references Secrets. A real production platform could move this to an external secret manager.

## Kubernetes persistence

The manifests demonstrate PVC-backed stateful services. They do not claim that a single local StatefulSet replica equals a complete HA production database platform.

## NetworkPolicy

The project uses default-deny plus explicit allowed flows. Actual enforcement still depends on the Kubernetes CNI supporting NetworkPolicy.

## Observability

Prometheus metrics and structured HTTP request logging are implemented. Future additions could include tracing, centralized logs, alerts and SLO dashboards.

## Nix

Nix improves reproducibility but adds tooling complexity. For this project, reproducible Haskell tooling is considered worth that cost.

## Principle

Optimizations and infrastructure additions should be driven by measured problems. The project deliberately distinguishes between what is implemented now and what would be a reasonable next production step.