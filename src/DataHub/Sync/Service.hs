{-# LANGUAGE OverloadedStrings #-}

module DataHub.Sync.Service
  ( SyncServiceError (..)
  , createGitHubSyncJob
  , findSyncJobById
  ) where

import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import qualified Data.Text as Text

import DataHub.Database (DatabasePool)
import qualified DataHub.Sync.Repository as Repository
import DataHub.Sync.Types
  ( CreateGitHubSyncRequest (..)
  , SyncJob
  )

data SyncServiceError
  = SyncQueryEmpty
  | SyncMaxItemsInvalid
  | SyncCategoryNotFound Int64
  | SyncJobNotFound Int64
  deriving (Eq, Show)

createGitHubSyncJob
  :: DatabasePool
  -> CreateGitHubSyncRequest
  -> IO (Either SyncServiceError SyncJob)
createGitHubSyncJob pool request = do

  let searchQuery =
        Text.strip
          (createSyncQuery request)

      maxItems =
        fromMaybe 20
          (createSyncMaxItems request)

  if Text.null searchQuery
    then
      pure (Left SyncQueryEmpty)

    else
      if maxItems < 1 || maxItems > 100
        then
          pure (Left SyncMaxItemsInvalid)

        else do
          result <-
            Repository.createGitHubSyncJob
              pool
              searchQuery
              (createSyncCategoryId request)
              maxItems

          pure $
            case result of
              Right job ->
                Right job

              Left
                (Repository.CreateSyncCategoryNotFound categoryId) ->
                  Left
                    (SyncCategoryNotFound categoryId)

findSyncJobById
  :: DatabasePool
  -> Int64
  -> IO (Either SyncServiceError SyncJob)
findSyncJobById pool jobId = do

  result <-
    Repository.findSyncJobById
      pool
      jobId

  pure $
    case result of
      Just job ->
        Right job

      Nothing ->
        Left (SyncJobNotFound jobId)