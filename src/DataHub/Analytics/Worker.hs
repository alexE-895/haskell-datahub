{-# LANGUAGE OverloadedStrings #-}

module DataHub.Analytics.Worker
  ( runAnalyticsWorkerForever
  , runAnalyticsWorkerOnce
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

import DataHub.Analytics.ClickHouse
  ( ClickHouseClient
  , insertAnalyticsEvent
  )
import DataHub.Analytics.Outbox
  ( claimPendingEvents
  , markEventFailed
  , markEventProcessed
  )
import DataHub.Analytics.Types
  ( AnalyticsEvent (..)
  )
import DataHub.Database (DatabasePool)

runAnalyticsWorkerOnce
  :: DatabasePool
  -> ClickHouseClient
  -> IO Int
runAnalyticsWorkerOnce pool clickHouse = do
  workerId <-
    makeWorkerId

  events <-
    claimPendingEvents
      pool
      workerId
      100

  putStrLn
    ( "Analytics worker claimed: "
        ++ show (length events)
    )

  forM_ events $ \event ->
    processEvent
      pool
      clickHouse
      workerId
      event

  pure (length events)

runAnalyticsWorkerForever
  :: DatabasePool
  -> ClickHouseClient
  -> IO ()
runAnalyticsWorkerForever pool clickHouse = do
  workerId <-
    makeWorkerId

  putStrLn
    ( "Analytics worker started: "
        ++ Text.unpack workerId
    )

  loop workerId
  where
    loop workerId = do
      events <-
        claimPendingEvents
          pool
          workerId
          100

      if null events
        then
          threadDelay 2000000

        else
          forM_ events $
            processEvent
              pool
              clickHouse
              workerId

      loop workerId

processEvent
  :: DatabasePool
  -> ClickHouseClient
  -> Text
  -> AnalyticsEvent
  -> IO ()
processEvent pool clickHouse workerId event = do
  result <-
    try
      (insertAnalyticsEvent clickHouse event)
      :: IO (Either SomeException ())

  case result of
    Right () -> do
      markEventProcessed
        pool
        workerId
        (analyticsEventId event)

      putStrLn
        ( "Analytics event processed: "
            ++ show (analyticsEventId event)
        )

    Left exception -> do
      let message =
            Text.pack (displayException exception)

      markEventFailed
        pool
        workerId
        (analyticsEventId event)
        message

      putStrLn
        ( "Analytics event failed: "
            ++ show (analyticsEventId event)
            ++ " "
            ++ displayException exception
        )

makeWorkerId :: IO Text
makeWorkerId = do
  now <- getCurrentTime
  threadId <- myThreadId

  pure
    ( Text.pack
        ( "worker-"
            ++ formatTime
                 defaultTimeLocale
                 "%Y%m%d%H%M%S%q"
                 now
            ++ "-"
            ++ filter (/= ' ') (show threadId)
        )
    )