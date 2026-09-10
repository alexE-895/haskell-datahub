{-# LANGUAGE OverloadedStrings #-}

module OutboxSpec (outboxSpec) where

import Control.Concurrent.Async (withAsync, wait)
import Control.Concurrent.MVar
import Control.Exception (bracket)
import Data.Int (Int64)
import Data.IORef
import Data.Pool (withResource)
import Database.PostgreSQL.Simple
import System.Timeout (timeout)
import Test.Hspec

import DataHub.Analytics.Outbox (claimPendingEvents, deliverClaimedEvent)
import DataHub.Analytics.Types (analyticsEventId)
import DataHub.Database (DatabasePool)

outboxSpec :: DatabasePool -> Spec
outboxSpec pool = describe "outbox ownership during delivery" $ do
  it "does not reclaim an expired event while its send holds the row lock" $
    withEvent $ \eventId -> do
      entered <- newEmptyMVar
      release <- newEmptyMVar
      sends <- newIORef (0 :: Int)
      let send = modifyIORef' sends (+ 1)
          firstSend = send >> putMVar entered () >> takeMVar release
      result <- timeout 10000000 $
        withAsync (deliverClaimedEvent pool "test-owner" eventId firstSend) $ \first -> do
          takeMVar entered
          claimed <- claimPendingEvents pool "other-owner" 100000
          map analyticsEventId claimed `shouldNotContain` [eventId]
          withAsync (deliverClaimedEvent pool "test-owner" eventId send) $ \second -> do
            putMVar release ()
            wait first `shouldReturn` True
            wait second `shouldReturn` False
      result `shouldBe` Just ()
      readIORef sends `shouldReturn` 1

  it "skips a stale owner after an expired batch is reclaimed" $
    withEvent $ \eventId -> do
      claimed <- claimPendingEvents pool "new-owner" 100000
      map analyticsEventId claimed `shouldContain` [eventId]
      deliverClaimedEvent pool "test-owner" eventId (error "stale owner sent event")
        `shouldReturn` False
      deliverClaimedEvent pool "new-owner" eventId (pure ()) `shouldReturn` True

  it "rolls back acknowledgement when delivery fails and permits retry" $
    withEvent $ \eventId -> do
      deliverClaimedEvent pool "test-owner" eventId (ioError (userError "send failed"))
        `shouldThrow` anyIOException
      deliverClaimedEvent pool "test-owner" eventId (pure ()) `shouldReturn` True
  where
    withEvent = bracket create remove
    create = withResource pool $ \connection -> do
      [Only eventId] <- query_ connection
        "INSERT INTO analytics_outbox (event_type, entity_type, entity_id, locked_at, locked_by) VALUES ('test', 'test', 1, NOW() - INTERVAL '6 minutes', 'test-owner') RETURNING id"
      pure (eventId :: Int64)
    remove eventId = withResource pool $ \connection -> do
      _ <- execute connection "DELETE FROM analytics_outbox WHERE id = ?" (Only eventId)
      -- Release only claims made by these tests, not application work.
      _ <- execute_ connection "UPDATE analytics_outbox SET locked_at = NULL, locked_by = NULL WHERE locked_by IN ('other-owner', 'new-owner')"
      pure ()
