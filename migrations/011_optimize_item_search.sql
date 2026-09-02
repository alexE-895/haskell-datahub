-- PostgreSQL item search/filter performance indexes.
--
-- Benchmark on 100,000 items:
--
-- ILIKE search COUNT:
--   before: ~69 ms
--   after:  ~2.6 ms
--
-- source COUNT:
--   before: ~8.6 ms
--   after:  ~2.9 ms

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX idx_items_name_trgm
    ON items
    USING gin (name gin_trgm_ops);

CREATE INDEX idx_items_description_trgm
    ON items
    USING gin ((COALESCE(description, '')) gin_trgm_ops);

CREATE INDEX idx_items_source
    ON items (source);