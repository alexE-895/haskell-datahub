ALTER TABLE stored_files
    ADD COLUMN status TEXT NOT NULL DEFAULT 'uploading',

    ADD COLUMN last_error TEXT,

    ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    ADD COLUMN deleted_at TIMESTAMPTZ;

ALTER TABLE stored_files
    ADD CONSTRAINT stored_files_status_valid
    CHECK (
        status IN (
            'uploading',
            'ready',
            'deleting',
            'failed',
            'deleted'
        )
    );

CREATE INDEX idx_stored_files_status
    ON stored_files(status);

CREATE TRIGGER stored_files_set_updated_at
BEFORE UPDATE ON stored_files
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();