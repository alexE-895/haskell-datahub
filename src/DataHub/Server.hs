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
  , findCategoryById
  , listCategories
  )
import DataHub.Types
  ( Category
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
  liftIO (listCategories databasePool)

categoryByIdHandler :: DatabasePool -> Int64 -> Handler Category
categoryByIdHandler databasePool categoryId = do
  category <- liftIO (findCategoryById databasePool categoryId)

  case category of
    Just foundCategory ->
      pure foundCategory

    Nothing ->
      throwError err404

server :: DatabasePool -> Server API
server databasePool =
       healthHandler
  :<|> readinessHandler databasePool
  :<|> categoriesHandler databasePool
  :<|> categoryByIdHandler databasePool

runServer :: DatabasePool -> IO ()
runServer databasePool = do
  putStrLn "Haskell DataHub listening on http://127.0.0.1:8080"
  run 8080 (serve apiProxy (server databasePool))