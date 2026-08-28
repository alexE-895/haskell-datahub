ALTER TABLE analytics_outbox
    ADD COLUMN locked_at TIMESTAMPTZ,
    ADD COLUMN locked_by TEXT;

CREATE INDEX idx_analytics_outbox_claim
    ON analytics_outbox (locked_at, id)
    WHERE processed_at IS NULL;