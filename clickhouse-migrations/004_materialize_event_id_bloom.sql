ALTER TABLE analytics_events
MATERIALIZE INDEX idx_event_id_bloom
SETTINGS mutations_sync = 1
