module DataHub.App
  ( runApp
  ) where

import DataHub.Server (runServer)

runApp :: IO ()
runApp = runServer