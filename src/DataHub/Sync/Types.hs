{-# LANGUAGE OverloadedStrings #-}

module DataHub.Sync.Types
  ( CreateGitHubSyncRequest (..)
  , SyncJob (..)
  ) where

import Data.Aeson
  ( FromJSON (parseJSON)
  , ToJSON (toJSON)
  , object
  , withObject
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)

data CreateGitHubSyncRequest =
  CreateGitHubSyncRequest
    { createSyncQuery :: Text
    , createSyncCategoryId :: Int64
    , createSyncMaxItems :: Maybe Int
    }

instance FromJSON CreateGitHubSyncRequest where
  parseJSON =
    withObject "CreateGitHubSyncRequest" $ \value ->
      CreateGitHubSyncRequest
        <$> value .: "query"
        <*> value .: "categoryId"
        <*> value .:? "maxItems"

data SyncJob = SyncJob
  { syncJobId :: Int64
  , syncJobProvider :: Text
  , syncJobQuery :: Text
  , syncJobCategoryId :: Int64
  , syncJobStatus :: Text
  , syncJobMaxItems :: Int
  , syncJobAttempts :: Int
  , syncJobResultCount :: Int
  , syncJobLastError :: Maybe Text
  , syncJobCreatedAt :: UTCTime
  , syncJobUpdatedAt :: UTCTime
  , syncJobCompletedAt :: Maybe UTCTime
  }
  deriving (Eq, Show)

instance FromJSON SyncJob where
  parseJSON =
    withObject "SyncJob" $ \value ->
      SyncJob
        <$> value .: "id"
        <*> value .: "provider"
        <*> value .: "query"
        <*> value .: "categoryId"
        <*> value .: "status"
        <*> value .: "maxItems"
        <*> value .: "attempts"
        <*> value .: "resultCount"
        <*> value .:? "lastError"
        <*> value .: "createdAt"
        <*> value .: "updatedAt"
        <*> value .:? "completedAt"

instance ToJSON SyncJob where
  toJSON job =
    object
      [ "id" .= syncJobId job
      , "provider" .= syncJobProvider job
      , "query" .= syncJobQuery job
      , "categoryId" .= syncJobCategoryId job
      , "status" .= syncJobStatus job
      , "maxItems" .= syncJobMaxItems job
      , "attempts" .= syncJobAttempts job
      , "resultCount" .= syncJobResultCount job
      , "lastError" .= syncJobLastError job
      , "createdAt" .= syncJobCreatedAt job
      , "updatedAt" .= syncJobUpdatedAt job
      , "completedAt" .= syncJobCompletedAt job
      ]