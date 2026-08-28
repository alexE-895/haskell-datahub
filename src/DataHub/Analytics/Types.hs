{-# LANGUAGE OverloadedStrings #-}

module DataHub.Analytics.Types
  ( AnalyticsEvent (..)
  , EventSummary (..)
  , ItemSourceStat (..)
  ) where

import Data.Aeson
  ( FromJSON (parseJSON)
  , ToJSON (toJSON)
  , object
  , withObject
  , (.:)
  , (.=)
  )
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)

data AnalyticsEvent = AnalyticsEvent
  { analyticsEventId :: Int64
  , analyticsEventTime :: UTCTime
  , analyticsEventType :: Text
  , analyticsEntityType :: Text
  , analyticsEntityId :: Int64
  , analyticsCategoryId :: Maybe Int64
  , analyticsSource :: Text
  , analyticsPayloadJson :: Text
  }
  deriving (Eq, Show)

instance ToJSON AnalyticsEvent where
  toJSON event =
    object
      [ "event_time" .= analyticsEventTime event
      , "event_id" .= analyticsEventId event
      , "event_type" .= analyticsEventType event
      , "entity_type" .= analyticsEntityType event
      , "entity_id" .= analyticsEntityId event
      , "category_id" .= analyticsCategoryId event
      , "source" .= analyticsSource event
      , "payload_json" .= analyticsPayloadJson event
      ]

data EventSummary = EventSummary
  { eventSummaryEventType :: Text
  , eventSummaryEntityType :: Text
  , eventSummaryTotal :: Int64
  }
  deriving (Eq, Show)

instance FromJSON EventSummary where
  parseJSON =
    withObject "EventSummary" $ \value ->
      EventSummary
        <$> value .: "eventType"
        <*> value .: "entityType"
        <*> value .: "total"

instance ToJSON EventSummary where
  toJSON summary =
    object
      [ "eventType" .= eventSummaryEventType summary
      , "entityType" .= eventSummaryEntityType summary
      , "total" .= eventSummaryTotal summary
      ]

data ItemSourceStat = ItemSourceStat
  { itemSourceStatSource :: Text
  , itemSourceStatEvents :: Int64
  , itemSourceStatUniqueItems :: Int64
  }
  deriving (Eq, Show)

instance FromJSON ItemSourceStat where
  parseJSON =
    withObject "ItemSourceStat" $ \value ->
      ItemSourceStat
        <$> value .: "source"
        <*> value .: "events"
        <*> value .: "uniqueItems"

instance ToJSON ItemSourceStat where
  toJSON stat =
    object
      [ "source" .= itemSourceStatSource stat
      , "events" .= itemSourceStatEvents stat
      , "uniqueItems" .= itemSourceStatUniqueItems stat
      ]