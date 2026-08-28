{-# LANGUAGE OverloadedStrings #-}

module DataHub.Item.Types
  ( CreateItemRequest (..)
  , Item (..)
  , ItemListQuery (..)
  , ItemListResponse (..)
  , NewItem (..)
  , UpdateItem (..)
  , UpdateItemRequest (..)
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

import DataHub.Types (PatchField (..))

data Item = Item
  { itemId :: Int64
  , itemCategoryId :: Int64
  , itemName :: Text
  , itemDescription :: Maybe Text
  , itemSource :: Text
  , itemExternalId :: Maybe Text
  }
  deriving (Eq, Show)

instance ToJSON Item where
  toJSON item =
    object
      [ "id" .= itemId item
      , "categoryId" .= itemCategoryId item
      , "name" .= itemName item
      , "description" .= itemDescription item
      , "source" .= itemSource item
      , "externalId" .= itemExternalId item
      ]

data CreateItemRequest = CreateItemRequest
  { createItemCategoryId :: Int64
  , createItemName :: Text
  , createItemDescription :: Maybe Text
  , createItemSource :: Maybe Text
  , createItemExternalId :: Maybe Text
  }

instance FromJSON CreateItemRequest where
  parseJSON =
    withObject "CreateItemRequest" $ \value ->
      CreateItemRequest
        <$> value .: "categoryId"
        <*> value .: "name"
        <*> value .:? "description"
        <*> value .:? "source"
        <*> value .:? "externalId"

data NewItem = NewItem
  { newItemCategoryId :: Int64
  , newItemName :: Text
  , newItemDescription :: Maybe Text
  , newItemSource :: Text
  , newItemExternalId :: Maybe Text
  }

data UpdateItemRequest = UpdateItemRequest
  { requestItemCategoryId :: PatchField Int64
  , requestItemName :: PatchField Text
  , requestItemDescription :: PatchField Text
  , requestItemSource :: PatchField Text
  , requestItemExternalId :: PatchField Text
  }
  deriving (Eq, Show)

instance FromJSON UpdateItemRequest where
  parseJSON =
    withObject "UpdateItemRequest" $ \value ->
      UpdateItemRequest
        <$> parsePatchField value "categoryId"
        <*> parsePatchField value "name"
        <*> parsePatchField value "description"
        <*> parsePatchField value "source"
        <*> parsePatchField value "externalId"

parsePatchField
  :: FromJSON a
  => Object
  -> Key
  -> Parser (PatchField a)
parsePatchField value key =
  case KeyMap.lookup key value of
    Nothing ->
      pure PatchKeep

    Just Null ->
      pure PatchClear

    Just fieldValue ->
      PatchSet <$> parseJSON fieldValue

data UpdateItem = UpdateItem
  { updateItemCategoryId :: Maybe Int64
  , updateItemName :: Maybe Text
  , updateItemDescription :: PatchField Text
  , updateItemSource :: Maybe Text
  , updateItemExternalId :: PatchField Text
  }

data ItemListQuery = ItemListQuery
  { itemQuerySearch :: Maybe Text
  , itemQueryCategoryId :: Maybe Int64
  , itemQuerySource :: Maybe Text
  , itemQueryLimit :: Int
  , itemQueryOffset :: Int
  }

data ItemListResponse = ItemListResponse
  { itemListItems :: [Item]
  , itemListTotal :: Int64
  , itemListLimit :: Int
  , itemListOffset :: Int
  }

instance ToJSON ItemListResponse where
  toJSON response =
    object
      [ "items" .= itemListItems response
      , "total" .= itemListTotal response
      , "limit" .= itemListLimit response
      , "offset" .= itemListOffset response
      ]