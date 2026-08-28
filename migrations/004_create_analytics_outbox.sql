CREATE TABLE analytics_outbox (
    id           BIGSERIAL PRIMARY KEY,

    event_type   TEXT NOT NULL,
    entity_type  TEXT NOT NULL,
    entity_id    BIGINT NOT NULL,
    category_id  BIGINT,

    source       TEXT NOT NULL DEFAULT 'system',
    payload_json TEXT NOT NULL DEFAULT '{}',

    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at TIMESTAMPTZ,

    attempts     INTEGER NOT NULL DEFAULT 0,
    last_error   TEXT,

    CONSTRAINT analytics_outbox_event_type_not_blank
        CHECK (btrim(event_type) <> ''),

    CONSTRAINT analytics_outbox_entity_type_not_blank
        CHECK (btrim(entity_type) <> ''),

    CONSTRAINT analytics_outbox_entity_id_positive
        CHECK (entity_id > 0),

    CONSTRAINT analytics_outbox_source_not_blank
        CHECK (btrim(source) <> ''),

    CONSTRAINT analytics_outbox_attempts_non_negative
        CHECK (attempts >= 0)
);

CREATE INDEX idx_analytics_outbox_pending
    ON analytics_outbox (id)
    WHERE processed_at IS NULL;

CREATE INDEX idx_analytics_outbox_created_at
    ON analytics_outbox (created_at);

CREATE INDEX idx_analytics_outbox_entity
    ON analytics_outbox (entity_type, entity_id);