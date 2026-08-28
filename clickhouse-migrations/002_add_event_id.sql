ALTER TABLE analytics_events
    ADD COLUMN IF NOT EXISTS event_id UInt64
    AFTER event_time;