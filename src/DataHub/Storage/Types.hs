{-# LANGUAGE OverloadedStrings #-}

module DataHub.Storage.Types
  ( StoredFile (..)
  ) where

import Data.Aeson
  ( ToJSON (toJSON)
  , object
  , (.=)
  )
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)

data StoredFile = StoredFile
  { storedFileId :: Int64
  , storedFileItemId :: Maybe Int64
  , storedFileBucketName :: Text
  , storedFileObjectKey :: Text
  , storedFileOriginalName :: Text
  , storedFileContentType :: Text
  , storedFileSizeBytes :: Int64
  , storedFileStorageProvider :: Text
  , storedFileStatus :: Text
  , storedFileLastError :: Maybe Text
  , storedFileCreatedAt :: UTCTime
  , storedFileUpdatedAt :: UTCTime
  , storedFileDeletedAt :: Maybe UTCTime
  }
  deriving (Eq, Show)

instance ToJSON StoredFile where
  toJSON file =
    object
      [ "id" .= storedFileId file
      , "itemId" .= storedFileItemId file
      , "bucketName" .= storedFileBucketName file
      , "objectKey" .= storedFileObjectKey file
      , "originalName" .= storedFileOriginalName file
      , "contentType" .= storedFileContentType file
      , "sizeBytes" .= storedFileSizeBytes file
      , "storageProvider" .= storedFileStorageProvider file
      , "status" .= storedFileStatus file
      , "lastError" .= storedFileLastError file
      , "createdAt" .= storedFileCreatedAt file
      , "updatedAt" .= storedFileUpdatedAt file
      , "deletedAt" .= storedFileDeletedAt file
      ]