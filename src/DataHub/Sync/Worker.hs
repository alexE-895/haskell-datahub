{-# LANGUAGE OverloadedStrings #-}

module DataHub.Sync.Worker
  ( runSyncWorkerForever
  , runSyncWorkerOnce
  ) where

import Control.Concurrent
  ( myThreadId
  , threadDelay
  )
import Control.Exception
  ( SomeException
  , displayException
  , try
  )
import Control.Monad (forM_)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time
  ( defaultTimeLocale
  , formatTime
  , getCurrentTime
  )

import DataHub.Database (DatabasePool)
import DataHub.External.GitHub
  ( GitHubClient
  , GitHubRepository
  , searchRepositories
  )
import DataHub.Sync.Repository
  ( claimSyncJobs
  , completeGitHubSyncJob
  , markSyncJobFailed
  )
import DataHub.Sync.Types
  ( SyncJob (..)
  )

runSyncWorkerOnce
  :: DatabasePool
  -> GitHubClient
  -> IO Int
runSyncWorkerOnce pool gitHub = do

  workerId <-
    makeWorkerId

  jobs <-
    claimSyncJobs
      pool
      workerId
      5

  putStrLn
    ( "Sync worker claimed jobs: "
        ++ show (length jobs)
    )

  forM_ jobs $
    processJob
      pool
      gitHub
      workerId

  pure (length jobs)

runSyncWorkerForever
  :: DatabasePool
  -> GitHubClient
  -> IO ()
runSyncWorkerForever pool gitHub = do

  workerId <-
    makeWorkerId

  putStrLn
    ( "Sync worker started: "
        ++ Text.unpack workerId
    )

  loop workerId

  where
    loop workerId = do

      jobs <-
        claimSyncJobs
          pool
          workerId
          5

      if null jobs
        then
          threadDelay 3000000

        else
          forM_ jobs $
            processJob
              pool
              gitHub
              workerId

      loop workerId

processJob
  :: DatabasePool
  -> GitHubClient
  -> Text
  -> SyncJob
  -> IO ()
processJob pool gitHub workerId job = do

  putStrLn
    ( "Sync job started: "
        ++ show (syncJobId job)
        ++ " query="
        ++ Text.unpack (syncJobQuery job)
    )

  fetchResult <-
    try
      ( searchRepositories
          gitHub
          (syncJobQuery job)
          (syncJobMaxItems job)
      )
      :: IO
          ( Either
              SomeException
              [GitHubRepository]
          )

  case fetchResult of
    Left exception ->
      failJob exception

    Right repositories -> do

      completionResult <-
        try
          ( completeGitHubSyncJob
              pool
              workerId
              job
              repositories
          )
          :: IO
              (Either SomeException Int)

      case completionResult of
        Left exception ->
          failJob exception

        Right resultCount ->
          putStrLn
            ( "Sync job completed: "
                ++ show (syncJobId job)
                ++ " items="
                ++ show resultCount
            )

  where
    failJob exception = do

      let errorText =
            Text.pack
              (displayException exception)

      markSyncJobFailed
        pool
        workerId
        (syncJobId job)
        errorText

      putStrLn
        ( "Sync job failed: "
            ++ show (syncJobId job)
            ++ " "
            ++ displayException exception
        )

makeWorkerId :: IO Text
makeWorkerId = do

  now <-
    getCurrentTime

  threadId <-
    myThreadId

  pure
    ( Text.pack
        ( "sync-worker-"
            ++ formatTime
                 defaultTimeLocale
                 "%Y%m%d%H%M%S%q"
                 now
            ++ "-"
            ++ filter (/= ' ')
                 (show threadId)
        )
    )