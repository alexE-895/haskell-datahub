{-# LANGUAGE OverloadedStrings #-}

module DataHub.Types
  ( Category (..)
  , HealthResponse (..)
  , ReadinessResponse (..)
  ) where

import Data.Aeson (ToJSON (toJSON), object, (.=))
import Data.Int (Int64)
import Data.Text (Text)

data Category = Category
  { categoryId :: Int64
  , categoryName :: Text
  , categoryDescription :: Maybe Text
  , categoryParentId :: Maybe Int64
  }

instance ToJSON Category where
  toJSON category =
    object
      [ "id" .= categoryId category
      , "name" .= categoryName category
      , "description" .= categoryDescription category
      , "parentId" .= categoryParentId category
      ]

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