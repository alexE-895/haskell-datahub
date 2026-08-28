ALTER TABLE analytics_outbox
    ADD COLUMN next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

DROP INDEX idx_analytics_outbox_claim;

CREATE INDEX idx_analytics_outbox_claim
    ON analytics_outbox (next_attempt_at, locked_at, id)
    WHERE processed_at IS NULL;