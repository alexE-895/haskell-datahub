BEGIN;

ALTER TABLE categories
    ADD CONSTRAINT categories_name_not_blank
        CHECK (btrim(name) <> ''),

    ADD CONSTRAINT categories_name_max_length
        CHECK (char_length(name) <= 120);

CREATE UNIQUE INDEX uq_categories_root_name_ci
    ON categories (lower(name))
    WHERE parent_id IS NULL;

CREATE UNIQUE INDEX uq_categories_sibling_name_ci
    ON categories (parent_id, lower(name))
    WHERE parent_id IS NOT NULL;

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER categories_set_updated_at
BEFORE UPDATE ON categories
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

COMMIT;