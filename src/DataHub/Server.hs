{-# LANGUAGE OverloadedStrings #-}

module DataHub.Server
  ( runServer
  ) where

import Control.Monad.IO.Class (liftIO)
import Network.Wai.Handler.Warp (run)
import Servant
  ( Handler
  , Server
  , err503
  , serve
  , throwError
  , (:<|>) (..)
  )

import DataHub.API (API, apiProxy)
import DataHub.Database
  ( DatabaseConfig
  , checkDatabase
  )
import DataHub.Types
  ( HealthResponse (HealthResponse)
  , ReadinessResponse (ReadinessResponse)
  )

healthHandler :: Handler HealthResponse
healthHandler =
  pure (HealthResponse "ok" "haskell-datahub")

readinessHandler :: DatabaseConfig -> Handler ReadinessResponse
readinessHandler databaseConfig = do
  databaseReady <- liftIO (checkDatabase databaseConfig)

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

server :: DatabaseConfig -> Server API
server databaseConfig =
  healthHandler
    :<|> readinessHandler databaseConfig

runServer :: DatabaseConfig -> IO ()
runServer databaseConfig = do
  putStrLn "Haskell DataHub listening on http://127.0.0.1:8080"
  run 8080 (serve apiProxy (server databaseConfig))