{-# LANGUAGE OverloadedStrings #-}

module DataHub.Server
  ( runServer
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Int (Int64)
import Network.Wai.Handler.Warp (run)
import Servant
  ( Handler
  , Server
  , err400
  , err404
  , err503
  , serve
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
  ( Category
  , CreateCategoryRequest
  , HealthResponse (HealthResponse)
  , ReadinessResponse (ReadinessResponse)
  )

healthHandler :: Handler HealthResponse
healthHandler =
  pure (HealthResponse "ok" "haskell-datahub")

readinessHandler :: DatabasePool -> Handler ReadinessResponse
readinessHandler databasePool = do
  databaseReady <- liftIO (checkDatabase databasePool)

  if databaseReady
    then
      pure
        ( ReadinessResponse
            "ready"
            "haskell-datahub"
            "ready"
        )
    else
      throwError err503

categoriesHandler :: DatabasePool -> Handler [Category]
categoriesHandler databasePool =
  liftIO (CategoryService.listCategories databasePool)

categoryByIdHandler :: DatabasePool -> Int64 -> Handler Category
categoryByIdHandler databasePool categoryId = do
  category <-
    liftIO
      (CategoryService.findCategoryById databasePool categoryId)

  case category of
    Just foundCategory ->
      pure foundCategory

    Nothing ->
      throwError err404

createCategoryHandler
  :: DatabasePool
  -> CreateCategoryRequest
  -> Handler Category
createCategoryHandler databasePool request = do
  result <-
    liftIO
      (CategoryService.createCategory databasePool request)

  case result of
    Right category ->
      pure category

    Left CategoryService.CategoryNameEmpty ->
      throwError err400

    Left CategoryService.CategoryNameTooLong ->
      throwError err400

    Left (CategoryService.CategoryParentNotFound _) ->
      throwError err404

server :: DatabasePool -> Server API
server databasePool =
       healthHandler
  :<|> readinessHandler databasePool
  :<|> categoriesHandler databasePool
  :<|> categoryByIdHandler databasePool
  :<|> createCategoryHandler databasePool

runServer :: DatabasePool -> IO ()
runServer databasePool = do
  putStrLn "Haskell DataHub listening on http://127.0.0.1:8080"
  run 8080 (serve apiProxy (server databasePool))