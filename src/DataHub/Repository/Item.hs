{-# LANGUAGE OverloadedStrings #-}

module DataHub.Repository.Item
  ( CreateItemRepositoryError (..)
  , DeleteItemRepositoryError (..)
  , UpdateItemRepositoryError (..)
  , createItem
  , deleteItem
  , findItemById
  , listItems
  , updateItem
  ) where

import Control.Exception
  ( throwIO
  , try
  )
import Data.Aeson
  ( object
  , (.=)
  )
import Data.Int (Int64)
import Data.Maybe
  ( fromMaybe
  , listToMaybe
  )
import Data.Pool (withResource)
import Data.Text (Text)
import Database.PostgreSQL.Simple
  ( Connection
  , Only (Only)
  , SqlError (..)
  , execute
  , query
  , withTransaction
  )
import Database.PostgreSQL.Simple.FromRow
  ( FromRow (fromRow)
  , field
  )

import DataHub.Analytics.Outbox
  ( enqueueAnalyticsEvent
  )
import DataHub.Database (DatabasePool)
import DataHub.Item.Types
  ( Item (..)
  , ItemListQuery (..)
  , NewItem (..)
  , UpdateItem (..)
  )
import DataHub.Types (PatchField (..))

newtype ItemRow = ItemRow
  { unItemRow :: Item
  }

instance FromRow ItemRow where
  fromRow =
    ItemRow
      <$> ( Item
              <$> field
              <*> field
              <*> field
              <*> field
              <*> field
              <*> field
          )

data CreateItemRepositoryError
  = CreateItemCategoryNotFound Int64
  | CreateItemConflict
  deriving (Eq, Show)

data UpdateItemRepositoryError
  = UpdateItemNotFound Int64
  | UpdateItemCategoryNotFound Int64
  | UpdateItemConflict
  deriving (Eq, Show)

data DeleteItemRepositoryError
  = DeleteItemNotFound Int64
  deriving (Eq, Show)

findItemById
  :: DatabasePool
  -> Int64
  -> IO (Maybe Item)
findItemById pool itemId =
  withResource pool $ \connection -> do
    rows <-
      query
        connection
        "SELECT id, category_id, name, description, source, external_id FROM items WHERE id = ?"
        (Only itemId)
        :: IO [ItemRow]

    pure (unItemRow <$> listToMaybe rows)

listItems
  :: DatabasePool
  -> ItemListQuery
  -> IO ([Item], Int64)
listItems pool listQuery =
  withResource pool $ \connection -> do
    rows <-
      query
        connection
        "SELECT id, category_id, name, description, source, external_id FROM items WHERE (?::text IS NULL OR name ILIKE '%' || ?::text || '%' OR COALESCE(description, '') ILIKE '%' || ?::text || '%') AND (?::bigint IS NULL OR category_id = ?::bigint) AND (?::text IS NULL OR source = ?::text) ORDER BY id LIMIT ? OFFSET ?"
        ( itemQuerySearch listQuery
        , itemQuerySearch listQuery
        , itemQuerySearch listQuery
        , itemQueryCategoryId listQuery
        , itemQueryCategoryId listQuery
        , itemQuerySource listQuery
        , itemQuerySource listQuery
        , itemQueryLimit listQuery
        , itemQueryOffset listQuery
        )
        :: IO [ItemRow]

    countRows <-
      query
        connection
        "SELECT COUNT(*) FROM items WHERE (?::text IS NULL OR name ILIKE '%' || ?::text || '%' OR COALESCE(description, '') ILIKE '%' || ?::text || '%') AND (?::bigint IS NULL OR category_id = ?::bigint) AND (?::text IS NULL OR source = ?::text)"
        ( itemQuerySearch listQuery
        , itemQuerySearch listQuery
        , itemQuerySearch listQuery
        , itemQueryCategoryId listQuery
        , itemQueryCategoryId listQuery
        , itemQuerySource listQuery
        , itemQuerySource listQuery
        )
        :: IO [Only Int64]

    case countRows of
      [Only total] ->
        pure
          ( map unItemRow rows
          , total
          )

      _ ->
        error "Item COUNT query returned unexpected row count"

createItem
  :: DatabasePool
  -> NewItem
  -> IO (Either CreateItemRepositoryError Item)
createItem pool newItem = do
  result <-
    try
      ( withResource pool $ \connection ->
          withTransaction connection $ do
            categoryExists <-
              categoryExistsForShare
                connection
                (newItemCategoryId newItem)

            if not categoryExists
              then
                pure
                  ( Left
                      ( CreateItemCategoryNotFound
                          (newItemCategoryId newItem)
                      )
                  )

              else do
                rows <-
                  query
                    connection
                    "INSERT INTO items (category_id, name, description, source, external_id) VALUES (?, ?, ?, ?, ?) RETURNING id, category_id, name, description, source, external_id"
                    ( newItemCategoryId newItem
                    , newItemName newItem
                    , newItemDescription newItem
                    , newItemSource newItem
                    , newItemExternalId newItem
                    )
                    :: IO [ItemRow]

                case rows of
                  [ItemRow item] -> do
                    enqueueItemEvent
                      connection
                      "item_created"
                      item

                    pure (Right item)

                  _ ->
                    error "INSERT item RETURNING produced unexpected row count"
      )
      :: IO
          ( Either
              SqlError
              (Either CreateItemRepositoryError Item)
          )

  case result of
    Right value ->
      pure value

    Left sqlError
      | sqlState sqlError == "23505" ->
          pure (Left CreateItemConflict)

      | otherwise ->
          throwIO sqlError

updateItem
  :: DatabasePool
  -> Int64
  -> UpdateItem
  -> IO (Either UpdateItemRepositoryError Item)
updateItem pool itemId updateRequest = do
  result <-
    try
      ( withResource pool $ \connection ->
          withTransaction connection $
            updateInsideTransaction
              connection
              itemId
              updateRequest
      )
      :: IO
          ( Either
              SqlError
              (Either UpdateItemRepositoryError Item)
          )

  case result of
    Right value ->
      pure value

    Left sqlError
      | sqlState sqlError == "23505" ->
          pure (Left UpdateItemConflict)

      | otherwise ->
          throwIO sqlError

deleteItem
  :: DatabasePool
  -> Int64
  -> IO (Either DeleteItemRepositoryError ())
deleteItem pool itemId =
  withResource pool $ \connection ->
    withTransaction connection $ do
      rows <-
        query
          connection
          "SELECT id, category_id, name, description, source, external_id FROM items WHERE id = ? FOR UPDATE"
          (Only itemId)
          :: IO [ItemRow]

      case listToMaybe rows of
        Nothing ->
          pure (Left (DeleteItemNotFound itemId))

        Just (ItemRow item) -> do
          affected <-
            execute
              connection
              "DELETE FROM items WHERE id = ?"
              (Only itemId)

          if affected == 1
            then do
              enqueueItemEvent
                connection
                "item_deleted"
                item

              pure (Right ())

            else
              error "DELETE item affected unexpected row count"

updateInsideTransaction
  :: Connection
  -> Int64
  -> UpdateItem
  -> IO (Either UpdateItemRepositoryError Item)
updateInsideTransaction connection itemId updateRequest = do
  currentRows <-
    query
      connection
      "SELECT id, category_id, name, description, source, external_id FROM items WHERE id = ? FOR UPDATE"
      (Only itemId)
      :: IO [ItemRow]

  case listToMaybe currentRows of
    Nothing ->
      pure (Left (UpdateItemNotFound itemId))

    Just (ItemRow currentItem) -> do
      let effectiveCategoryId =
            fromMaybe
              (itemCategoryId currentItem)
              (updateItemCategoryId updateRequest)

          effectiveName =
            fromMaybe
              (itemName currentItem)
              (updateItemName updateRequest)

          effectiveDescription =
            applyNullablePatch
              (itemDescription currentItem)
              (updateItemDescription updateRequest)

          effectiveSource =
            fromMaybe
              (itemSource currentItem)
              (updateItemSource updateRequest)

          effectiveExternalId =
            applyNullablePatch
              (itemExternalId currentItem)
              (updateItemExternalId updateRequest)

      categoryExists <-
        categoryExistsForShare
          connection
          effectiveCategoryId

      if not categoryExists
        then
          pure
            ( Left
                (UpdateItemCategoryNotFound effectiveCategoryId)
            )

        else do
          rows <-
            query
              connection
              "UPDATE items SET category_id = ?, name = ?, description = ?, source = ?, external_id = ? WHERE id = ? RETURNING id, category_id, name, description, source, external_id"
              ( effectiveCategoryId
              , effectiveName
              , effectiveDescription
              , effectiveSource
              , effectiveExternalId
              , itemId
              )
              :: IO [ItemRow]

          case rows of
            [ItemRow updatedItem] -> do
              enqueueItemEvent
                connection
                "item_updated"
                updatedItem

              pure (Right updatedItem)

            _ ->
              error "UPDATE item RETURNING produced unexpected row count"

enqueueItemEvent
  :: Connection
  -> Text
  -> Item
  -> IO ()
enqueueItemEvent connection eventType item =
  enqueueAnalyticsEvent
    connection
    eventType
    "item"
    (itemId item)
    (Just (itemCategoryId item))
    (itemSource item)
    ( object
        [ "id" .= itemId item
        , "categoryId" .= itemCategoryId item
        , "name" .= itemName item
        , "description" .= itemDescription item
        , "source" .= itemSource item
        , "externalId" .= itemExternalId item
        ]
    )

categoryExistsForShare
  :: Connection
  -> Int64
  -> IO Bool
categoryExistsForShare connection categoryId = do
  rows <-
    query
      connection
      "SELECT id FROM categories WHERE id = ? FOR KEY SHARE"
      (Only categoryId)
      :: IO [Only Int64]

  pure (not (null rows))

applyNullablePatch
  :: Maybe a
  -> PatchField a
  -> Maybe a
applyNullablePatch currentValue patch =
  case patch of
    PatchKeep ->
      currentValue

    PatchClear ->
      Nothing

    PatchSet value ->
      Just value