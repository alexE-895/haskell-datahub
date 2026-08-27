{-# LANGUAGE OverloadedStrings #-}

module DataHub.Types
  ( HealthResponse (..)
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