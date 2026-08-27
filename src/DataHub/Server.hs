{-# LANGUAGE OverloadedStrings #-}

module DataHub.Server
  ( runServer
  ) where

import Network.Wai.Handler.Warp (run)
import Servant (Handler, Server, serve)

import DataHub.API (API, apiProxy)
import DataHub.Types (HealthResponse (HealthResponse))

healthHandler :: Handler HealthResponse
healthHandler =
  pure (HealthResponse "ok" "haskell-datahub")

server :: Server API
server = healthHandler

runServer :: IO ()
runServer = do
  putStrLn "Haskell DataHub listening on http://127.0.0.1:8080"
  run 8080 (serve apiProxy server)