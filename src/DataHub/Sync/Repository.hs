{-# LANGUAGE OverloadedStrings #-}

module DataHub.Sync.Repository
  ( CreateSyncJobRepositoryError (..)
  , claimSyncJobs
  , completeGitHubSyncJob
  , createGitHubSyncJob
  , findSyncJobById
  , markSyncJobFailed
  ) where

import Control.Monad
  ( forM
  , unless
  )
import Data.Aeson
  ( object
  , (.=)
  )
import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Data.Pool (withResource)
import Data.Text (Text)
import qualified Data.Text as Text
import Database.PostgreSQL.Simple
  ( Connection
  , Only (Only)
  , execute
  , query
  , withTransaction
  )
import Database.PostgreSQL.Simple.FromRow
  ( FromRow (fromRow)
  , field
  )

import DataHub.Analytics.Outbox
  ( enqueueAnalyticsEvent
  )
import DataHub.Database (DatabasePool)
import DataHub.External.GitHub
  ( GitHubRepository (..)
  )
import DataHub.Sync.Types
  ( SyncJob (..)
  )

newtype SyncJobRow =
  SyncJobRow
    { unSyncJobRow :: SyncJob
    }

instance FromRow SyncJobRow where
  fromRow =
    SyncJobRow
      <$> ( SyncJob
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
          )

data CreateSyncJobRepositoryError
  = CreateSyncCategoryNotFound Int64
  deriving (Eq, Show)

createGitHubSyncJob
  :: DatabasePool
  -> Text
  -> Int64
  -> Int
  -> IO
      ( Either
          CreateSyncJobRepositoryError
          SyncJob
      )
createGitHubSyncJob pool searchQuery categoryId maxItems =
  withResource pool $ \connection ->
    withTransaction connection $ do

      categoryRows <-
        query
          connection
          "SELECT id FROM categories WHERE id = ? FOR KEY SHARE"
          (Only categoryId)
          :: IO [Only Int64]

      if null categoryRows
        then
          pure
            ( Left
                (CreateSyncCategoryNotFound categoryId)
            )

        else do
          rows <-
            query
              connection
              "INSERT INTO external_sync_jobs (provider, query_text, category_id, max_items) VALUES ('github', ?, ?, ?) RETURNING id, provider, query_text, category_id, status, max_items, attempts, result_count, last_error, created_at, updated_at, completed_at"
              ( searchQuery
              , categoryId
              , maxItems
              )
              :: IO [SyncJobRow]

          case rows of
            [SyncJobRow job] ->
              pure (Right job)

            _ ->
              error
                "INSERT external_sync_jobs RETURNING unexpected row count"

findSyncJobById
  :: DatabasePool
  -> Int64
  -> IO (Maybe SyncJob)
findSyncJobById pool jobId =
  withResource pool $ \connection -> do

    rows <-
      query
        connection
        "SELECT id, provider, query_text, category_id, status, max_items, attempts, result_count, last_error, created_at, updated_at, completed_at FROM external_sync_jobs WHERE id = ?"
        (Only jobId)
        :: IO [SyncJobRow]

    pure
      (unSyncJobRow <$> listToMaybe rows)

claimSyncJobs
  :: DatabasePool
  -> Text
  -> Int
  -> IO [SyncJob]
claimSyncJobs pool workerId batchSize =
  withResource pool $ \connection ->
    withTransaction connection $ do

      rows <-
        query
          connection
          "WITH candidates AS (SELECT id FROM external_sync_jobs WHERE attempts < 5 AND next_attempt_at <= NOW() AND ((status IN ('pending','failed') AND locked_at IS NULL) OR (status = 'running' AND (locked_at IS NULL OR locked_at < NOW() - INTERVAL '5 minutes'))) ORDER BY id FOR UPDATE SKIP LOCKED LIMIT ?) UPDATE external_sync_jobs AS j SET status = 'running', locked_at = NOW(), locked_by = ? FROM candidates AS c WHERE j.id = c.id RETURNING j.id, j.provider, j.query_text, j.category_id, j.status, j.max_items, j.attempts, j.result_count, j.last_error, j.created_at, j.updated_at, j.completed_at"
          (batchSize, workerId)
          :: IO [SyncJobRow]

      pure
        (map unSyncJobRow rows)

markSyncJobFailed
  :: DatabasePool
  -> Text
  -> Int64
  -> Text
  -> IO ()
markSyncJobFailed pool workerId jobId errorMessage =
  withResource pool $ \connection -> do

    let safeError =
          Text.take 4000 errorMessage

    _ <-
      execute
        connection
        "UPDATE external_sync_jobs SET status = 'failed', attempts = attempts + 1, last_error = ?, next_attempt_at = NOW() + (LEAST(300, CAST(power(2, LEAST(attempts + 1, 8)) AS integer)) * INTERVAL '1 second'), locked_at = NULL, locked_by = NULL WHERE id = ? AND locked_by = ?"
        ( safeError
        , jobId
        , workerId
        )

    pure ()

completeGitHubSyncJob
  :: DatabasePool
  -> Text
  -> SyncJob
  -> [GitHubRepository]
  -> IO Int
completeGitHubSyncJob pool workerId job repositories =
  withResource pool $ \connection ->
    withTransaction connection $ do

      itemIds <-
        forM repositories $ \repository ->
          upsertGitHubRepository
            connection
            job
            repository

      let resultCount =
            length itemIds

      affected <-
        execute
          connection
          "UPDATE external_sync_jobs SET status = 'completed', result_count = ?, completed_at = NOW(), last_error = NULL, locked_at = NULL, locked_by = NULL WHERE id = ? AND locked_by = ? AND status = 'running'"
          ( resultCount
          , syncJobId job
          , workerId
          )

      unless (affected == 1) $
        error
          "SYNC_JOB_COMPLETION_LOCK_LOST"

      enqueueAnalyticsEvent
        connection
        "sync_completed"
        "sync_job"
        (syncJobId job)
        (Just (syncJobCategoryId job))
        "github"
        ( object
            [ "jobId" .= syncJobId job
            , "query" .= syncJobQuery job
            , "resultCount" .= resultCount
            ]
        )

      pure resultCount

upsertGitHubRepository
  :: Connection
  -> SyncJob
  -> GitHubRepository
  -> IO Int64
upsertGitHubRepository connection job repository = do

  let externalId =
        Text.pack
          (show (gitHubRepositoryId repository))

  rows <-
    query
      connection
      "INSERT INTO items (category_id, name, description, source, external_id) VALUES (?, ?, ?, 'github', ?) ON CONFLICT (source, external_id) WHERE external_id IS NOT NULL DO UPDATE SET category_id = EXCLUDED.category_id, name = EXCLUDED.name, description = EXCLUDED.description, updated_at = NOW() RETURNING id"
      ( syncJobCategoryId job
      , gitHubRepositoryFullName repository
      , gitHubRepositoryDescription repository
      , externalId
      )
      :: IO [Only Int64]

  itemId <-
    case rows of
      [Only value] ->
        pure value

      _ ->
        error
          "GitHub item UPSERT RETURNING unexpected row count"

  enqueueAnalyticsEvent
    connection
    "item_synced"
    "item"
    itemId
    (Just (syncJobCategoryId job))
    "github"
    ( object
        [ "repositoryId" .= gitHubRepositoryId repository
        , "fullName" .= gitHubRepositoryFullName repository
        , "url" .= gitHubRepositoryHtmlUrl repository
        , "stars" .= gitHubRepositoryStars repository
        , "language" .= gitHubRepositoryLanguage repository
        , "syncJobId" .= syncJobId job
        ]
    )

  pure itemId