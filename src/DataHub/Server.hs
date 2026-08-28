{-# LANGUAGE OverloadedStrings #-}

module DataHub.Server
  ( runServer
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson
  ( Value
  , encode
  , object
  , (.=)
  )
import Data.Int (Int64)
import Data.Text (Text)
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

import DataHub.API (API, apiProxy)
import DataHub.Database
  ( DatabasePool
  , checkDatabase
  )
import qualified DataHub.Service.Category as CategoryService
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
        encode
          (ApiError code message details)
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
  databaseReady <- liftIO (checkDatabase databasePool)

  if databaseReady
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
  liftIO (CategoryService.listCategories databasePool)

categoryByIdHandler
  :: DatabasePool
  -> Int64
  -> Handler Category
categoryByIdHandler databasePool categoryId = do
  category <-
    liftIO
      (CategoryService.findCategoryById databasePool categoryId)

  case category of
    Just foundCategory ->
      pure foundCategory

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

    Left (CategoryService.CategoryNotFound missingId) ->
      throwApiError
        err404
        "CATEGORY_NOT_FOUND"
        "Category does not exist"
        (Just (object ["categoryId" .= missingId]))

    Left (CategoryService.CategoryHasChildren parentId) ->
      throwApiError
        err409
        "CATEGORY_HAS_CHILDREN"
        "Category cannot be deleted while it has child categories"
        (Just (object ["categoryId" .= parentId]))

    Left otherError ->
      handleCategoryError otherError

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
      throwApiError
        err400
        "CATEGORY_NAME_EMPTY"
        "Category name must not be empty"
        Nothing

    CategoryService.CategoryNameTooLong ->
      throwApiError
        err400
        "CATEGORY_NAME_TOO_LONG"
        "Category name must not exceed 120 characters"
        Nothing

    CategoryService.CategoryNameConflict ->
      throwApiError
        err409
        "CATEGORY_NAME_CONFLICT"
        "A category with this name already exists under the same parent"
        Nothing

    CategoryService.CategoryNotFound categoryId ->
      throwApiError
        err404
        "CATEGORY_NOT_FOUND"
        "Category does not exist"
        (Just (object ["categoryId" .= categoryId]))

    CategoryService.CategoryParentNotFound parentId ->
      throwApiError
        err404
        "PARENT_CATEGORY_NOT_FOUND"
        "Parent category does not exist"
        (Just (object ["parentId" .= parentId]))

    CategoryService.CategoryCycleDetected categoryId parentId ->
      throwApiError
        err409
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
      throwApiError
        err409
        "CATEGORY_HAS_CHILDREN"
        "Category cannot be deleted while it has child categories"
        (Just (object ["categoryId" .= categoryId]))

    CategoryService.CategoryUpdateEmpty ->
      throwApiError
        err400
        "CATEGORY_UPDATE_EMPTY"
        "At least one category field must be provided"
        Nothing

server :: DatabasePool -> Server API
server databasePool =
       healthHandler
  :<|> readinessHandler databasePool
  :<|> categoriesHandler databasePool
  :<|> categoryByIdHandler databasePool
  :<|> createCategoryHandler databasePool
  :<|> updateCategoryHandler databasePool
  :<|> deleteCategoryHandler databasePool

runServer :: DatabasePool -> IO ()
runServer databasePool = do
  putStrLn "Haskell DataHub listening on http://127.0.0.1:8080"

  run
    8080
    ( serveWithContext
        apiProxy
        (customErrorFormatters :. EmptyContext)
        (server databasePool)
    )