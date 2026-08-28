CREATE TABLE stored_files (
    id              BIGSERIAL PRIMARY KEY,

    item_id         BIGINT
        REFERENCES items(id)
        ON DELETE SET NULL,

    bucket_name     TEXT NOT NULL,
    object_key      TEXT NOT NULL,

    original_name   TEXT NOT NULL,
    content_type    TEXT NOT NULL,

    size_bytes      BIGINT NOT NULL,

    storage_provider TEXT NOT NULL DEFAULT 's3',

    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT stored_files_bucket_not_blank
        CHECK (btrim(bucket_name) <> ''),

    CONSTRAINT stored_files_object_key_not_blank
        CHECK (btrim(object_key) <> ''),

    CONSTRAINT stored_files_original_name_not_blank
        CHECK (btrim(original_name) <> ''),

    CONSTRAINT stored_files_content_type_not_blank
        CHECK (btrim(content_type) <> ''),

    CONSTRAINT stored_files_size_non_negative
        CHECK (size_bytes >= 0)
);

CREATE UNIQUE INDEX uq_stored_files_bucket_object
    ON stored_files(bucket_name, object_key);

CREATE INDEX idx_stored_files_item
    ON stored_files(item_id);

CREATE INDEX idx_stored_files_created_at
    ON stored_files(created_at DESC);