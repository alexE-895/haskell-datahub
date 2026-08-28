CREATE TABLE IF NOT EXISTS analytics_events
(
    event_time DateTime64(3, 'UTC') DEFAULT now64(3),

    event_type LowCardinality(String),

    entity_type LowCardinality(String),

    entity_id UInt64,

    category_id Nullable(UInt64),

    source LowCardinality(String) DEFAULT 'system',

    payload_json String DEFAULT '{}'
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY
(
    entity_type,
    event_type,
    event_time,
    entity_id
)
TTL event_time + INTERVAL 365 DAY DELETE
SETTINGS index_granularity = 8192