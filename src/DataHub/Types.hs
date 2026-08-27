{-# LANGUAGE OverloadedStrings #-}

module DataHub.Types
  ( HealthResponse (..)
  , ReadinessResponse (..)
  ) where

import Data.Aeson (ToJSON (toJSON), object, (.=))
import Data.Text (Text)

data HealthResponse = HealthResponse
  { healthStatus :: Text
  , healthService :: Text
  }

instance ToJSON HealthResponse where
  toJSON response =
    object
      [ "status" .= healthStatus response
      , "service" .= healthService response
      ]

data ReadinessResponse = ReadinessResponse
  { readinessStatus :: Text
  , readinessService :: Text
  , readinessDatabase :: Text
  }

instance ToJSON ReadinessResponse where
  toJSON response =
    object
      [ "status" .= readinessStatus response
      , "service" .= readinessService response
      , "database" .= readinessDatabase response
      ]