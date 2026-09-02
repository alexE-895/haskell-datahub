ALTER TABLE analytics_events
ADD INDEX IF NOT EXISTS idx_event_id_bloom
event_id
TYPE bloom_filter(0.01)
GRANULARITY 1
