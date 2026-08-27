module DataHub.App
  ( runApp
  ) where

import DataHub.Database
  ( checkDatabase
  , createDatabasePool
  , loadDatabaseConfig
  )
import DataHub.Server (runServer)

runApp :: IO ()
runApp = do
  databaseConfig <- loadDatabaseConfig
  databasePool <- createDatabasePool databaseConfig

  databaseReady <- checkDatabase databasePool

  if databaseReady
    then putStrLn "PostgreSQL connection pool: OK"
    else putStrLn "PostgreSQL connection pool: FAILED"

  runServer databasePool