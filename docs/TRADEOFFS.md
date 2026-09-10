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

## Delivery guarantees

Claims expire after five minutes. Before sending each event, the worker locks
its PostgreSQL row and verifies the owner and unprocessed state. The lock stays
held across the ClickHouse call and acknowledgement, so another worker cannot
reclaim an in-flight event; a stale owner skips events already reclaimed.
The worker applies a 30-second application deadline to the ClickHouse call.
This uses a database connection and transaction for the duration of the send,
an acceptable trade-off for the current sequential polling worker.

The ClickHouse existence check prevents sequential replay of visible events.
It is not an atomic uniqueness constraint. If an insert times out but continues
on the server, a retry can check before that insert becomes visible and create
a duplicate. Loss of the PostgreSQL connection during a remote send is another
ambiguous case. The guarantee is at-least-once, not exactly-once. Current raw
`count()` reports can overcount if duplicates occur in these cases.

Tests exercise concurrent delivery ownership, expired claims and rollback after
a failed send. The CI replay scenario resets PostgreSQL delivery state after
successful insertion; it does not simulate a network partition or kill a process.

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

The API limits request bodies to 10 MiB before Servant handlers run. Known
oversized bodies are rejected without reading; unknown-length bodies are stopped
while reading and return HTTP 413. The same limit applies to JSON requests.
File uploads use temporary files before S3 upload; this is not streaming to S3.

For much larger objects, streaming or pre-signed multipart uploads would be a better design.

File metadata and S3 operations are not one transaction. Process termination or
an intermediate persistence failure can leave `uploading`/`deleting` records or
orphaned objects. There is no automatic reconciler; recovery requires inspecting
the metadata and object store and repairing the state manually. This limitation
is intentional for the local demonstration. Normal request cleanup removes
temporary files, but cannot run after a hard process kill.

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
