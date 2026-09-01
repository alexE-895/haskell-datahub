{-# LANGUAGE OverloadedStrings #-}
module DataHub.Service.Item
  ( ItemServiceError (..)
  , createItem
  , deleteItem
  , findItemById
  , listItems
  , updateItem
  ) where

import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text

import DataHub.Database (DatabasePool)
import DataHub.Domain.Id
  ( CategoryId
  , ItemId
  , entityIdToInt64
  )
import DataHub.Item.Types
  ( CreateItemRequest (..)
  , Item
  , ItemListQuery (ItemListQuery)
  , ItemListResponse (ItemListResponse)
  , NewItem (NewItem)
  , UpdateItem (UpdateItem)
  , UpdateItemRequest (..)
  )
import qualified DataHub.Repository.Item as Repository
import DataHub.Types (PatchField (..))

data ItemServiceError
  = ItemNotFound Int64
  | ItemCategoryNotFound Int64
  | ItemNameEmpty
  | ItemNameTooLong
  | ItemSourceEmpty
  | ItemSourceTooLong
  | ItemExternalIdEmpty
  | ItemCategoryRequired
  | ItemConflict
  | ItemUpdateEmpty
  | ItemLimitInvalid
  | ItemOffsetInvalid
  deriving (Eq, Show)

findItemById
  :: DatabasePool
  -> ItemId
  -> IO (Maybe Item)
findItemById pool itemId =
  Repository.findItemById
    pool
    (entityIdToInt64 itemId)

listItems
  :: DatabasePool
  -> Maybe Text
  -> Maybe CategoryId
  -> Maybe Text
  -> Maybe Int
  -> Maybe Int
  -> IO (Either ItemServiceError ItemListResponse)
listItems pool search categoryId source requestedLimit requestedOffset = do
  let limitValue =
        fromMaybe 20 requestedLimit

      offsetValue =
        fromMaybe 0 requestedOffset

      normalizedSearch =
        normalizeOptionalText search

      normalizedSource =
        normalizeOptionalText source

  if limitValue < 1 || limitValue > 100
    then
      pure (Left ItemLimitInvalid)

    else
      if offsetValue < 0
        then
          pure (Left ItemOffsetInvalid)

        else do
          let listQuery =
                ItemListQuery
                  normalizedSearch
                  (entityIdToInt64 <$> categoryId)
                  normalizedSource
                  limitValue
                  offsetValue

          (items, total) <-
            Repository.listItems pool listQuery

          pure
            ( Right
                ( ItemListResponse
                    items
                    total
                    limitValue
                    offsetValue
                )
            )

createItem
  :: DatabasePool
  -> CreateItemRequest
  -> IO (Either ItemServiceError Item)
createItem pool request =
  case validateCreate request of
    Left serviceError ->
      pure (Left serviceError)

    Right newItem -> do
      repositoryResult <-
        Repository.createItem pool newItem

      pure $
        case repositoryResult of
          Right item ->
            Right item

          Left (Repository.CreateItemCategoryNotFound categoryId) ->
            Left (ItemCategoryNotFound categoryId)

          Left Repository.CreateItemConflict ->
            Left ItemConflict

updateItem
  :: DatabasePool
  -> ItemId
  -> UpdateItemRequest
  -> IO (Either ItemServiceError Item)
updateItem pool itemId request
  | isEmptyUpdate request =
      pure (Left ItemUpdateEmpty)

  | otherwise =
      case normalizeUpdate request of
        Left serviceError ->
          pure (Left serviceError)

        Right updateValue -> do
          repositoryResult <-
            Repository.updateItem
              pool
              (entityIdToInt64 itemId)
              updateValue

          pure $
            case repositoryResult of
              Right item ->
                Right item

              Left (Repository.UpdateItemNotFound missingId) ->
                Left (ItemNotFound missingId)

              Left (Repository.UpdateItemCategoryNotFound categoryId) ->
                Left (ItemCategoryNotFound categoryId)

              Left Repository.UpdateItemConflict ->
                Left ItemConflict

deleteItem
  :: DatabasePool
  -> ItemId
  -> IO (Either ItemServiceError ())
deleteItem pool itemId = do
  repositoryResult <-
    Repository.deleteItem
      pool
      (entityIdToInt64 itemId)

  pure $
    case repositoryResult of
      Right () ->
        Right ()

      Left (Repository.DeleteItemNotFound missingId) ->
        Left (ItemNotFound missingId)

validateCreate
  :: CreateItemRequest
  -> Either ItemServiceError NewItem
validateCreate request = do
  name <-
    validateName
      (createItemName request)

  source <-
    validateSource
      (fromMaybe "manual" (createItemSource request))

  externalId <-
    validateExternalId
      (createItemExternalId request)

  pure
    ( NewItem
        (createItemCategoryId request)
        name
        (normalizeOptionalText (createItemDescription request))
        source
        externalId
    )

normalizeUpdate
  :: UpdateItemRequest
  -> Either ItemServiceError UpdateItem
normalizeUpdate request = do
  categoryId <-
    case requestItemCategoryId request of
      PatchKeep ->
        Right Nothing

      PatchClear ->
        Left ItemCategoryRequired

      PatchSet value ->
        Right (Just value)

  name <-
    case requestItemName request of
      PatchKeep ->
        Right Nothing

      PatchClear ->
        Left ItemNameEmpty

      PatchSet value ->
        Just <$> validateName value

  source <-
    case requestItemSource request of
      PatchKeep ->
        Right Nothing

      PatchClear ->
        Left ItemSourceEmpty

      PatchSet value ->
        Just <$> validateSource value

  externalId <-
    case requestItemExternalId request of
      PatchKeep ->
        Right PatchKeep

      PatchClear ->
        Right PatchClear

      PatchSet value ->
        case normalizeRequiredText value of
          Nothing ->
            Left ItemExternalIdEmpty

          Just normalized ->
            Right (PatchSet normalized)

  let description =
        case requestItemDescription request of
          PatchKeep ->
            PatchKeep

          PatchClear ->
            PatchClear

          PatchSet value ->
            case normalizeRequiredText value of
              Nothing -> PatchClear
              Just normalized -> PatchSet normalized

  pure
    ( UpdateItem
        categoryId
        name
        description
        source
        externalId
    )

validateName
  :: Text
  -> Either ItemServiceError Text
validateName rawValue =
  let value = Text.strip rawValue
   in if Text.null value
        then Left ItemNameEmpty
        else
          if Text.length value > 200
            then Left ItemNameTooLong
            else Right value

validateSource
  :: Text
  -> Either ItemServiceError Text
validateSource rawValue =
  let value = Text.strip rawValue
   in if Text.null value
        then Left ItemSourceEmpty
        else
          if Text.length value > 64
            then Left ItemSourceTooLong
            else Right value

validateExternalId
  :: Maybe Text
  -> Either ItemServiceError (Maybe Text)
validateExternalId Nothing =
  Right Nothing

validateExternalId (Just rawValue) =
  case normalizeRequiredText rawValue of
    Nothing ->
      Left ItemExternalIdEmpty

    Just value ->
      Right (Just value)

normalizeOptionalText :: Maybe Text -> Maybe Text
normalizeOptionalText Nothing =
  Nothing

normalizeOptionalText (Just rawValue) =
  normalizeRequiredText rawValue

normalizeRequiredText :: Text -> Maybe Text
normalizeRequiredText rawValue =
  let value = Text.strip rawValue
   in if Text.null value
        then Nothing
        else Just value

isEmptyUpdate :: UpdateItemRequest -> Bool
isEmptyUpdate request =
  requestItemCategoryId request == PatchKeep
    && requestItemName request == PatchKeep
    && requestItemDescription request == PatchKeep
    && requestItemSource request == PatchKeep
    && requestItemExternalId request == PatchKeep