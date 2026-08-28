DROP INDEX IF EXISTS idx_external_sync_jobs_pending;

CREATE INDEX idx_external_sync_jobs_claim
    ON external_sync_jobs (
        next_attempt_at,
        locked_at,
        id
    )
    WHERE status IN (
        'pending',
        'failed',
        'running'
    );