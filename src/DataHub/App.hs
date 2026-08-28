module DataHub.App
  ( runApp
  , runMigrationsApp
  ) where

import Control.Monad (unless)

import DataHub.Database
  ( checkDatabase
  , createDatabasePool
  , loadDatabaseConfig
  )
import DataHub.Migrations (runMigrations)
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

runMigrationsApp :: IO ()
runMigrationsApp = do
  databaseConfig <- loadDatabaseConfig
  databasePool <- createDatabasePool databaseConfig

  databaseReady <- checkDatabase databasePool

  unless databaseReady $
    ioError
      (userError "PostgreSQL is unavailable")

  runMigrations databasePool "migrations"