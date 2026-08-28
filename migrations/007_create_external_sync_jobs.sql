CREATE TABLE external_sync_jobs (
    id              BIGSERIAL PRIMARY KEY,

    provider        TEXT NOT NULL,
    query_text      TEXT NOT NULL,

    category_id     BIGINT NOT NULL
        REFERENCES categories(id)
        ON DELETE RESTRICT,

    status          TEXT NOT NULL DEFAULT 'pending',

    max_items       INTEGER NOT NULL DEFAULT 20,

    attempts        INTEGER NOT NULL DEFAULT 0,
    result_count    INTEGER NOT NULL DEFAULT 0,

    last_error      TEXT,

    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    locked_at       TIMESTAMPTZ,
    locked_by       TEXT,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    completed_at    TIMESTAMPTZ,

    CONSTRAINT external_sync_jobs_provider_not_blank
        CHECK (btrim(provider) <> ''),

    CONSTRAINT external_sync_jobs_query_not_blank
        CHECK (btrim(query_text) <> ''),

    CONSTRAINT external_sync_jobs_status_valid
        CHECK (
            status IN (
                'pending',
                'running',
                'completed',
                'failed'
            )
        ),

    CONSTRAINT external_sync_jobs_max_items_valid
        CHECK (
            max_items >= 1
            AND max_items <= 100
        ),

    CONSTRAINT external_sync_jobs_attempts_non_negative
        CHECK (attempts >= 0),

    CONSTRAINT external_sync_jobs_result_count_non_negative
        CHECK (result_count >= 0)
);

CREATE INDEX idx_external_sync_jobs_pending
    ON external_sync_jobs (
        next_attempt_at,
        id
    )
    WHERE status IN ('pending', 'failed');

CREATE INDEX idx_external_sync_jobs_category
    ON external_sync_jobs(category_id);

CREATE INDEX idx_external_sync_jobs_created_at
    ON external_sync_jobs(created_at DESC);

CREATE TRIGGER external_sync_jobs_set_updated_at
BEFORE UPDATE ON external_sync_jobs
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();