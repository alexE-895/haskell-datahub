CREATE TABLE items (
    id          BIGSERIAL PRIMARY KEY,

    category_id BIGINT NOT NULL
        REFERENCES categories(id)
        ON DELETE RESTRICT,

    name        TEXT NOT NULL,
    description TEXT,

    source      TEXT NOT NULL DEFAULT 'manual',
    external_id TEXT,

    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT items_name_not_blank
        CHECK (btrim(name) <> ''),

    CONSTRAINT items_name_max_length
        CHECK (char_length(name) <= 200),

    CONSTRAINT items_source_not_blank
        CHECK (btrim(source) <> ''),

    CONSTRAINT items_source_max_length
        CHECK (char_length(source) <= 64),

    CONSTRAINT items_external_id_not_blank
        CHECK (
            external_id IS NULL
            OR btrim(external_id) <> ''
        )
);

CREATE INDEX idx_items_category_id
    ON items(category_id);

CREATE INDEX idx_items_created_at
    ON items(created_at DESC);

CREATE UNIQUE INDEX uq_items_category_name_ci
    ON items(category_id, lower(name));

CREATE UNIQUE INDEX uq_items_source_external_id
    ON items(source, external_id)
    WHERE external_id IS NOT NULL;

CREATE TRIGGER items_set_updated_at
BEFORE UPDATE ON items
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();