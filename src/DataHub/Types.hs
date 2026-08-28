{-# LANGUAGE OverloadedStrings #-}

module DataHub.Types
  ( ApiError (..)
  , Category (..)
  , CreateCategoryRequest (..)
  , HealthResponse (..)
  , NewCategory (..)
  , PatchField (..)
  , ReadinessResponse (..)
  , UpdateCategory (..)
  , UpdateCategoryRequest (..)
  ) where

import Data.Aeson
  ( FromJSON (parseJSON)
  , Object
  , ToJSON (toJSON)
  , Value (Null)
  , object
  , withObject
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Parser)
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

data CreateCategoryRequest = CreateCategoryRequest
  { createCategoryName :: Text
  , createCategoryDescription :: Maybe Text
  , createCategoryParentId :: Maybe Int64
  }

instance FromJSON CreateCategoryRequest where
  parseJSON =
    withObject "CreateCategoryRequest" $ \objectValue ->
      CreateCategoryRequest
        <$> objectValue .: "name"
        <*> objectValue .:? "description"
        <*> objectValue .:? "parentId"

data NewCategory = NewCategory
  { newCategoryName :: Text
  , newCategoryDescription :: Maybe Text
  , newCategoryParentId :: Maybe Int64
  }

data PatchField a
  = PatchKeep
  | PatchSet a
  | PatchClear
  deriving (Eq, Show)

data UpdateCategoryRequest = UpdateCategoryRequest
  { requestCategoryName :: PatchField Text
  , requestCategoryDescription :: PatchField Text
  , requestCategoryParentId :: PatchField Int64
  }
  deriving (Eq, Show)

instance FromJSON UpdateCategoryRequest where
  parseJSON =
    withObject "UpdateCategoryRequest" $ \objectValue ->
      UpdateCategoryRequest
        <$> parsePatchField objectValue "name"
        <*> parsePatchField objectValue "description"
        <*> parsePatchField objectValue "parentId"

parsePatchField
  :: FromJSON a
  => Object
  -> Key
  -> Parser (PatchField a)
parsePatchField objectValue key =
  case KeyMap.lookup key objectValue of
    Nothing ->
      pure PatchKeep

    Just Null ->
      pure PatchClear

    Just value ->
      PatchSet <$> parseJSON value

data UpdateCategory = UpdateCategory
  { updateCategoryName :: Maybe Text
  , updateCategoryDescription :: PatchField Text
  , updateCategoryParentId :: PatchField Int64
  }

data ApiError = ApiError
  { apiErrorCode :: Text
  , apiErrorMessage :: Text
  , apiErrorDetails :: Maybe Value
  }

instance ToJSON ApiError where
  toJSON apiError =
    object
      [ "code" .= apiErrorCode apiError
      , "message" .= apiErrorMessage apiError
      , "details" .= apiErrorDetails apiError
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