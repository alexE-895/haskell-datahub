{-# LANGUAGE OverloadedStrings #-}

module DataHub.Analytics.Outbox
  ( claimPendingEvents
  , enqueueAnalyticsEvent
  , markEventFailed
  , markEventProcessed
  ) where

import Data.Aeson
  ( Value
  , encode
  )
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Int (Int64)
import Data.Pool (withResource)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple
  ( Connection
  , execute
  , query
  , withTransaction
  )
import Database.PostgreSQL.Simple.FromRow
  ( FromRow (fromRow)
  , field
  )

import DataHub.Analytics.Types
  ( AnalyticsEvent (AnalyticsEvent)
  )
import DataHub.Database (DatabasePool)

data OutboxRow = OutboxRow
  { outboxId :: Int64
  , outboxCreatedAt :: UTCTime
  , outboxEventType :: Text
  , outboxEntityType :: Text
  , outboxEntityId :: Int64
  , outboxCategoryId :: Maybe Int64
  , outboxSource :: Text
  , outboxPayloadJson :: Text
  }

instance FromRow OutboxRow where
  fromRow =
    OutboxRow
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

enqueueAnalyticsEvent
  :: Connection
  -> Text
  -> Text
  -> Int64
  -> Maybe Int64
  -> Text
  -> Value
  -> IO ()
enqueueAnalyticsEvent
  connection
  eventType
  entityType
  entityId
  categoryId
  source
  payload = do

    let payloadText =
          Text.decodeUtf8
            (LazyByteString.toStrict (encode payload))

    _ <-
      execute
        connection
        "INSERT INTO analytics_outbox (event_type, entity_type, entity_id, category_id, source, payload_json) VALUES (?, ?, ?, ?, ?, ?)"
        ( eventType
        , entityType
        , entityId
        , categoryId
        , source
        , payloadText
        )

    pure ()

claimPendingEvents
  :: DatabasePool
  -> Text
  -> Int
  -> IO [AnalyticsEvent]
claimPendingEvents pool workerId batchSize =
  withResource pool $ \connection ->
    withTransaction connection $ do

      rows <-
        query
          connection
          "WITH candidates AS (SELECT id FROM analytics_outbox WHERE processed_at IS NULL AND next_attempt_at <= NOW() AND (locked_at IS NULL OR locked_at < NOW() - INTERVAL '5 minutes') ORDER BY id FOR UPDATE SKIP LOCKED LIMIT ?) UPDATE analytics_outbox AS o SET locked_at = NOW(), locked_by = ? FROM candidates AS c WHERE o.id = c.id RETURNING o.id, o.created_at, o.event_type, o.entity_type, o.entity_id, o.category_id, o.source, o.payload_json"
          (batchSize, workerId)
          :: IO [OutboxRow]

      pure (map toAnalyticsEvent rows)

markEventProcessed
  :: DatabasePool
  -> Text
  -> Int64
  -> IO ()
markEventProcessed pool workerId eventId =
  withResource pool $ \connection -> do

    _ <-
      execute
        connection
        "UPDATE analytics_outbox SET processed_at = NOW(), locked_at = NULL, locked_by = NULL, last_error = NULL WHERE id = ? AND locked_by = ?"
        (eventId, workerId)

    pure ()

markEventFailed
  :: DatabasePool
  -> Text
  -> Int64
  -> Text
  -> IO ()
markEventFailed pool workerId eventId errorMessage =
  withResource pool $ \connection -> do

    let safeError =
          Text.take 4000 errorMessage

    _ <-
      execute
        connection
        "UPDATE analytics_outbox SET attempts = attempts + 1, last_error = ?, next_attempt_at = NOW() + (LEAST(300, CAST(power(2, LEAST(attempts + 1, 8)) AS integer)) * INTERVAL '1 second'), locked_at = NULL, locked_by = NULL WHERE id = ? AND locked_by = ?"
        (safeError, eventId, workerId)

    pure ()

toAnalyticsEvent
  :: OutboxRow
  -> AnalyticsEvent
toAnalyticsEvent row =
  AnalyticsEvent
    (outboxId row)
    (outboxCreatedAt row)
    (outboxEventType row)
    (outboxEntityType row)
    (outboxEntityId row)
    (outboxCategoryId row)
    (outboxSource row)
    (outboxPayloadJson row)