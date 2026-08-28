{-# LANGUAGE OverloadedStrings #-}

module DataHub.Storage.Repository
  ( CreateStoredFileError (..)
  , createUploadingFile
  , findStoredFileById
  , markStoredFileDeleted
  , markStoredFileDeleting
  , markStoredFileFailed
  , markStoredFileReady
  ) where

import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Data.Pool (withResource)
import Data.Text (Text)
import qualified Data.Text as Text

import Database.PostgreSQL.Simple
  ( Only (Only)
  , execute
  , query
  , withTransaction
  )

import Database.PostgreSQL.Simple.FromRow
  ( FromRow (fromRow)
  , field
  )

import DataHub.Database
  ( DatabasePool
  )

import DataHub.Storage.Types
  ( StoredFile (..)
  )

newtype StoredFileRow =
  StoredFileRow
    { unStoredFileRow :: StoredFile
    }

instance FromRow StoredFileRow where
  fromRow =
    StoredFileRow
      <$> ( StoredFile
              <$> field
              <*> field
              <*> field
              <*> field
              <*> field
              <*> field
              <*> field
              <*> field
              <*> field
              <*> field
              <*> field
              <*> field
              <*> field
          )

data CreateStoredFileError
  = StoredFileItemNotFound Int64
  deriving (Eq, Show)

createUploadingFile
  :: DatabasePool
  -> Maybe Int64
  -> Text
  -> Text
  -> Text
  -> Text
  -> Int64
  -> IO (Either CreateStoredFileError StoredFile)
createUploadingFile
  pool
  itemId
  bucketName
  objectKey
  originalName
  contentType
  sizeBytes =

  withResource pool $ \connection ->
    withTransaction connection $ do

      itemExists <-
        case itemId of

          Nothing ->
            pure True

          Just value -> do
            rows <-
              query
                connection
                "SELECT id FROM items WHERE id = ? FOR KEY SHARE"
                (Only value)
                :: IO [Only Int64]

            pure (not (null rows))

      if not itemExists
        then
          pure
            ( Left
                ( StoredFileItemNotFound
                    (maybe 0 id itemId)
                )
            )

        else do

          rows <-
            query
              connection
              "INSERT INTO stored_files (item_id, bucket_name, object_key, original_name, content_type, size_bytes, storage_provider, status) VALUES (?, ?, ?, ?, ?, ?, 's3', 'uploading') RETURNING id, item_id, bucket_name, object_key, original_name, content_type, size_bytes, storage_provider, status, last_error, created_at, updated_at, deleted_at"
              ( itemId
              , bucketName
              , objectKey
              , originalName
              , contentType
              , sizeBytes
              )
              :: IO [StoredFileRow]

          case rows of
            [StoredFileRow file] ->
              pure (Right file)

            _ ->
              error
                "stored_files INSERT returned unexpected row count"

findStoredFileById
  :: DatabasePool
  -> Int64
  -> IO (Maybe StoredFile)
findStoredFileById pool fileId =
  withResource pool $ \connection -> do

    rows <-
      query
        connection
        "SELECT id, item_id, bucket_name, object_key, original_name, content_type, size_bytes, storage_provider, status, last_error, created_at, updated_at, deleted_at FROM stored_files WHERE id = ?"
        (Only fileId)
        :: IO [StoredFileRow]

    pure
      ( unStoredFileRow
          <$> listToMaybe rows
      )

markStoredFileReady
  :: DatabasePool
  -> Int64
  -> IO (Maybe StoredFile)
markStoredFileReady pool fileId =
  withResource pool $ \connection -> do

    rows <-
      query
        connection
        "UPDATE stored_files SET status = 'ready', last_error = NULL WHERE id = ? AND status = 'uploading' RETURNING id, item_id, bucket_name, object_key, original_name, content_type, size_bytes, storage_provider, status, last_error, created_at, updated_at, deleted_at"
        (Only fileId)
        :: IO [StoredFileRow]

    pure
      ( unStoredFileRow
          <$> listToMaybe rows
      )

markStoredFileDeleting
  :: DatabasePool
  -> Int64
  -> IO (Maybe StoredFile)
markStoredFileDeleting pool fileId =
  withResource pool $ \connection -> do

    rows <-
      query
        connection
        "UPDATE stored_files SET status = 'deleting', last_error = NULL WHERE id = ? AND status IN ('ready','failed') RETURNING id, item_id, bucket_name, object_key, original_name, content_type, size_bytes, storage_provider, status, last_error, created_at, updated_at, deleted_at"
        (Only fileId)
        :: IO [StoredFileRow]

    pure
      ( unStoredFileRow
          <$> listToMaybe rows
      )

markStoredFileDeleted
  :: DatabasePool
  -> Int64
  -> IO ()
markStoredFileDeleted pool fileId =
  withResource pool $ \connection -> do

    _ <-
      execute
        connection
        "UPDATE stored_files SET status = 'deleted', deleted_at = NOW(), last_error = NULL WHERE id = ?"
        (Only fileId)

    pure ()

markStoredFileFailed
  :: DatabasePool
  -> Int64
  -> Text
  -> IO ()
markStoredFileFailed pool fileId errorMessage =
  withResource pool $ \connection -> do

    _ <-
      execute
        connection
        "UPDATE stored_files SET status = 'failed', last_error = ? WHERE id = ? AND status <> 'deleted'"
        ( Text.take 4000 errorMessage
        , fileId
        )

    pure ()