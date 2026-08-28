{-# LANGUAGE OverloadedStrings #-}

module DataHub.Server
  ( application
  , runServer
  ) where

import Control.Exception
  ( SomeException
  , try
  )
import Control.Monad.IO.Class (liftIO)
import Data.Aeson
  ( Value
  , encode
  , object
  , (.=)
  )
import Data.Int (Int64)
import Data.Text (Text)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (run)
import Servant
  ( Context (..)
  , ErrorFormatters (..)
  , Handler
  , NoContent (NoContent)
  , Server
  , ServerError (..)
  , defaultErrorFormatters
  , err400
  , err404
  , err409
  , err503
  , serveWithContext
  , throwError
  , (:<|>) (..)
  )

import DataHub.Analytics.ClickHouse
  ( ClickHouseClient
  , queryEventSummary
  , queryItemsBySource
  )
import DataHub.Analytics.Types
  ( EventSummary
  , ItemSourceStat
  )
import DataHub.API (API, apiProxy)
import DataHub.Database
  ( DatabasePool
  , checkDatabase
  )
import DataHub.Item.Types
  ( CreateItemRequest
  , Item
  , ItemListResponse
  , UpdateItemRequest
  )
import qualified DataHub.Service.Category as CategoryService
import qualified DataHub.Service.Item as ItemService
import qualified DataHub.Sync.Service as SyncService
import DataHub.Sync.Types
  ( CreateGitHubSyncRequest
  , SyncJob
  )
import DataHub.Types
  ( ApiError (ApiError)
  , Category
  , CreateCategoryRequest
  , HealthResponse (HealthResponse)
  , ReadinessResponse (ReadinessResponse)
  , UpdateCategoryRequest
  )

jsonError
  :: ServerError
  -> Text
  -> Text
  -> Maybe Value
  -> ServerError
jsonError baseError code message details =
  baseError
    { errBody =
        encode (ApiError code message details)
    , errHeaders =
        ("Content-Type", "application/json;charset=utf-8")
          : errHeaders baseError
    }

throwApiError
  :: ServerError
  -> Text
  -> Text
  -> Maybe Value
  -> Handler a
throwApiError baseError code message details =
  throwError
    (jsonError baseError code message details)

customErrorFormatters :: ErrorFormatters
customErrorFormatters =
  defaultErrorFormatters
    { bodyParserErrorFormatter =
        \_ _ _ ->
          jsonError
            err400
            "INVALID_REQUEST_BODY"
            "Request body is invalid"
            Nothing

    , urlParseErrorFormatter =
        \_ _ _ ->
          jsonError
            err400
            "INVALID_PATH_PARAMETER"
            "Request path or query parameter is invalid"
            Nothing

    , headerParseErrorFormatter =
        \_ _ _ ->
          jsonError
            err400
            "INVALID_REQUEST_HEADER"
            "Request header is invalid"
            Nothing

    , notFoundErrorFormatter =
        \_ ->
          jsonError
            err404
            "ROUTE_NOT_FOUND"
            "Requested API route does not exist"
            Nothing
    }

healthHandler :: Handler HealthResponse
healthHandler =
  pure (HealthResponse "ok" "haskell-datahub")

readinessHandler :: DatabasePool -> Handler ReadinessResponse
readinessHandler databasePool = do
  ready <- liftIO (checkDatabase databasePool)

  if ready
    then
      pure
        (ReadinessResponse "ready" "haskell-datahub" "ready")
    else
      throwApiError
        err503
        "DATABASE_UNAVAILABLE"
        "PostgreSQL is unavailable"
        Nothing

categoriesHandler :: DatabasePool -> Handler [Category]
categoriesHandler databasePool =
  liftIO
    (CategoryService.listCategories databasePool)

categoryByIdHandler
  :: DatabasePool
  -> Int64
  -> Handler Category
categoryByIdHandler databasePool categoryId = do
  result <-
    liftIO
      (CategoryService.findCategoryById databasePool categoryId)

  case result of
    Just category ->
      pure category

    Nothing ->
      throwApiError
        err404
        "CATEGORY_NOT_FOUND"
        "Category does not exist"
        (Just (object ["categoryId" .= categoryId]))

createCategoryHandler
  :: DatabasePool
  -> CreateCategoryRequest
  -> Handler Category
createCategoryHandler databasePool request = do
  result <-
    liftIO
      (CategoryService.createCategory databasePool request)

  handleCategoryResult result

updateCategoryHandler
  :: DatabasePool
  -> Int64
  -> UpdateCategoryRequest
  -> Handler Category
updateCategoryHandler databasePool categoryId request = do
  result <-
    liftIO
      (CategoryService.updateCategory databasePool categoryId request)

  handleCategoryResult result

deleteCategoryHandler
  :: DatabasePool
  -> Int64
  -> Handler NoContent
deleteCategoryHandler databasePool categoryId = do
  result <-
    liftIO
      (CategoryService.deleteCategory databasePool categoryId)

  case result of
    Right () ->
      pure NoContent

    Left serviceError ->
      handleCategoryError serviceError

handleCategoryResult
  :: Either CategoryService.CategoryServiceError Category
  -> Handler Category
handleCategoryResult result =
  case result of
    Right category ->
      pure category

    Left serviceError ->
      handleCategoryError serviceError

handleCategoryError
  :: CategoryService.CategoryServiceError
  -> Handler a
handleCategoryError serviceError =
  case serviceError of
    CategoryService.CategoryNameEmpty ->
      throwApiError err400
        "CATEGORY_NAME_EMPTY"
        "Category name must not be empty"
        Nothing

    CategoryService.CategoryNameTooLong ->
      throwApiError err400
        "CATEGORY_NAME_TOO_LONG"
        "Category name must not exceed 120 characters"
        Nothing

    CategoryService.CategoryNameConflict ->
      throwApiError err409
        "CATEGORY_NAME_CONFLICT"
        "A category with this name already exists under the same parent"
        Nothing

    CategoryService.CategoryNotFound categoryId ->
      throwApiError err404
        "CATEGORY_NOT_FOUND"
        "Category does not exist"
        (Just (object ["categoryId" .= categoryId]))

    CategoryService.CategoryParentNotFound parentId ->
      throwApiError err404
        "PARENT_CATEGORY_NOT_FOUND"
        "Parent category does not exist"
        (Just (object ["parentId" .= parentId]))

    CategoryService.CategoryCycleDetected categoryId parentId ->
      throwApiError err409
        "CATEGORY_CYCLE_DETECTED"
        "Category hierarchy cycle detected"
        ( Just
            ( object
                [ "categoryId" .= categoryId
                , "parentId" .= parentId
                ]
            )
        )

    CategoryService.CategoryHasChildren categoryId ->
      throwApiError err409
        "CATEGORY_HAS_CHILDREN"
        "Category cannot be deleted while it has child categories"
        (Just (object ["categoryId" .= categoryId]))

    CategoryService.CategoryUpdateEmpty ->
      throwApiError err400
        "CATEGORY_UPDATE_EMPTY"
        "At least one category field must be provided"
        Nothing

itemsHandler
  :: DatabasePool
  -> Maybe Text
  -> Maybe Int64
  -> Maybe Text
  -> Maybe Int
  -> Maybe Int
  -> Handler ItemListResponse
itemsHandler databasePool search categoryId source limit offset = do
  result <-
    liftIO
      ( ItemService.listItems
          databasePool
          search
          categoryId
          source
          limit
          offset
      )

  case result of
    Right response ->
      pure response

    Left serviceError ->
      handleItemError serviceError

itemByIdHandler
  :: DatabasePool
  -> Int64
  -> Handler Item
itemByIdHandler databasePool itemId = do
  result <-
    liftIO
      (ItemService.findItemById databasePool itemId)

  case result of
    Just item ->
      pure item

    Nothing ->
      throwApiError err404
        "ITEM_NOT_FOUND"
        "Item does not exist"
        (Just (object ["itemId" .= itemId]))

createItemHandler
  :: DatabasePool
  -> CreateItemRequest
  -> Handler Item
createItemHandler databasePool request = do
  result <-
    liftIO
      (ItemService.createItem databasePool request)

  handleItemResult result

updateItemHandler
  :: DatabasePool
  -> Int64
  -> UpdateItemRequest
  -> Handler Item
updateItemHandler databasePool itemId request = do
  result <-
    liftIO
      (ItemService.updateItem databasePool itemId request)

  handleItemResult result

deleteItemHandler
  :: DatabasePool
  -> Int64
  -> Handler NoContent
deleteItemHandler databasePool itemId = do
  result <-
    liftIO
      (ItemService.deleteItem databasePool itemId)

  case result of
    Right () ->
      pure NoContent

    Left serviceError ->
      handleItemError serviceError

handleItemResult
  :: Either ItemService.ItemServiceError Item
  -> Handler Item
handleItemResult result =
  case result of
    Right item ->
      pure item

    Left serviceError ->
      handleItemError serviceError

handleItemError
  :: ItemService.ItemServiceError
  -> Handler a
handleItemError serviceError =
  case serviceError of
    ItemService.ItemNotFound itemId ->
      throwApiError err404
        "ITEM_NOT_FOUND"
        "Item does not exist"
        (Just (object ["itemId" .= itemId]))

    ItemService.ItemCategoryNotFound categoryId ->
      throwApiError err404
        "ITEM_CATEGORY_NOT_FOUND"
        "Item category does not exist"
        (Just (object ["categoryId" .= categoryId]))

    ItemService.ItemNameEmpty ->
      throwApiError err400
        "ITEM_NAME_EMPTY"
        "Item name must not be empty"
        Nothing

    ItemService.ItemNameTooLong ->
      throwApiError err400
        "ITEM_NAME_TOO_LONG"
        "Item name must not exceed 200 characters"
        Nothing

    ItemService.ItemSourceEmpty ->
      throwApiError err400
        "ITEM_SOURCE_EMPTY"
        "Item source must not be empty"
        Nothing

    ItemService.ItemSourceTooLong ->
      throwApiError err400
        "ITEM_SOURCE_TOO_LONG"
        "Item source must not exceed 64 characters"
        Nothing

    ItemService.ItemExternalIdEmpty ->
      throwApiError err400
        "ITEM_EXTERNAL_ID_EMPTY"
        "External item id must not be empty"
        Nothing

    ItemService.ItemCategoryRequired ->
      throwApiError err400
        "ITEM_CATEGORY_REQUIRED"
        "Item category cannot be null"
        Nothing

    ItemService.ItemConflict ->
      throwApiError err409
        "ITEM_CONFLICT"
        "Item conflicts with an existing item"
        Nothing

    ItemService.ItemUpdateEmpty ->
      throwApiError err400
        "ITEM_UPDATE_EMPTY"
        "At least one item field must be provided"
        Nothing

    ItemService.ItemLimitInvalid ->
      throwApiError err400
        "ITEM_LIMIT_INVALID"
        "Limit must be between 1 and 100"
        Nothing

    ItemService.ItemOffsetInvalid ->
      throwApiError err400
        "ITEM_OFFSET_INVALID"
        "Offset must be zero or greater"
        Nothing

createGitHubSyncHandler
  :: DatabasePool
  -> CreateGitHubSyncRequest
  -> Handler SyncJob
createGitHubSyncHandler databasePool request = do
  result <-
    liftIO
      ( SyncService.createGitHubSyncJob
          databasePool
          request
      )

  case result of
    Right job ->
      pure job

    Left serviceError ->
      handleSyncError serviceError

syncJobByIdHandler
  :: DatabasePool
  -> Int64
  -> Handler SyncJob
syncJobByIdHandler databasePool jobId = do
  result <-
    liftIO
      ( SyncService.findSyncJobById
          databasePool
          jobId
      )

  case result of
    Right job ->
      pure job

    Left serviceError ->
      handleSyncError serviceError

handleSyncError
  :: SyncService.SyncServiceError
  -> Handler a
handleSyncError serviceError =
  case serviceError of

    SyncService.SyncQueryEmpty ->
      throwApiError
        err400
        "SYNC_QUERY_EMPTY"
        "Sync query must not be empty"
        Nothing

    SyncService.SyncMaxItemsInvalid ->
      throwApiError
        err400
        "SYNC_MAX_ITEMS_INVALID"
        "maxItems must be between 1 and 100"
        Nothing

    SyncService.SyncCategoryNotFound categoryId ->
      throwApiError
        err404
        "SYNC_CATEGORY_NOT_FOUND"
        "Sync target category does not exist"
        (Just (object ["categoryId" .= categoryId]))

    SyncService.SyncJobNotFound jobId ->
      throwApiError
        err404
        "SYNC_JOB_NOT_FOUND"
        "Sync job does not exist"
        (Just (object ["jobId" .= jobId]))
analyticsEventSummaryHandler
  :: ClickHouseClient
  -> Handler [EventSummary]
analyticsEventSummaryHandler clickHouse = do
  result <-
    liftIO
      ( try (queryEventSummary clickHouse)
          :: IO (Either SomeException [EventSummary])
      )

  case result of
    Right summary ->
      pure summary

    Left _ ->
      throwApiError
        err503
        "ANALYTICS_UNAVAILABLE"
        "Analytics service is unavailable"
        Nothing

analyticsItemsBySourceHandler
  :: ClickHouseClient
  -> Handler [ItemSourceStat]
analyticsItemsBySourceHandler clickHouse = do
  result <-
    liftIO
      ( try (queryItemsBySource clickHouse)
          :: IO (Either SomeException [ItemSourceStat])
      )

  case result of
    Right stats ->
      pure stats

    Left _ ->
      throwApiError
        err503
        "ANALYTICS_UNAVAILABLE"
        "Analytics service is unavailable"
        Nothing

server
  :: DatabasePool
  -> ClickHouseClient
  -> Server API
server databasePool clickHouse =
       healthHandler
  :<|> readinessHandler databasePool

  :<|> categoriesHandler databasePool
  :<|> categoryByIdHandler databasePool
  :<|> createCategoryHandler databasePool
  :<|> updateCategoryHandler databasePool
  :<|> deleteCategoryHandler databasePool

  :<|> itemsHandler databasePool
  :<|> itemByIdHandler databasePool
  :<|> createItemHandler databasePool
  :<|> updateItemHandler databasePool
  :<|> deleteItemHandler databasePool

  :<|> createGitHubSyncHandler databasePool
  :<|> syncJobByIdHandler databasePool

  :<|> analyticsEventSummaryHandler clickHouse
  :<|> analyticsItemsBySourceHandler clickHouse

application
  :: DatabasePool
  -> ClickHouseClient
  -> Application
application databasePool clickHouse =
  serveWithContext
    apiProxy
    (customErrorFormatters :. EmptyContext)
    (server databasePool clickHouse)

runServer
  :: DatabasePool
  -> ClickHouseClient
  -> IO ()
runServer databasePool clickHouse = do
  putStrLn
    "Haskell DataHub listening on http://127.0.0.1:8080"

  run
    8080
    (application databasePool clickHouse)