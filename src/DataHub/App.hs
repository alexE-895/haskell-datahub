module DataHub.App
  ( runApp
  ) where

import DataHub.Database
  ( checkDatabase
  , loadDatabaseConfig
  )
import DataHub.Server (runServer)

runApp :: IO ()
runApp = do
  databaseConfig <- loadDatabaseConfig
  databaseReady <- checkDatabase databaseConfig

  if databaseReady
    then putStrLn "PostgreSQL connection: OK"
    else putStrLn "PostgreSQL connection: FAILED"

  runServer databaseConfig