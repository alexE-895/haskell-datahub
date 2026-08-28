module DataHub.App
  ( runAnalyticsWorkerForeverApp
  , runAnalyticsWorkerOnceApp
  , runApp
  , runClickHouseMigrationsApp
  , runMigrationsApp
  ) where

import Control.Monad (unless)

import DataHub.Analytics.ClickHouse
  ( ClickHouseClient
  , checkClickHouse
  , createClickHouseClient
  , loadClickHouseConfig
  , runClickHouseMigrations
  )
import DataHub.Analytics.Worker
  ( runAnalyticsWorkerForever
  , runAnalyticsWorkerOnce
  )
import DataHub.Database
  ( DatabasePool
  , checkDatabase
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

  clickHouseConfig <- loadClickHouseConfig
  clickHouse <- createClickHouseClient clickHouseConfig

  putStrLn "ClickHouse analytics client: configured"

  runServer databasePool clickHouse

runMigrationsApp :: IO ()
runMigrationsApp = do
  databaseConfig <- loadDatabaseConfig
  databasePool <- createDatabasePool databaseConfig

  databaseReady <- checkDatabase databasePool

  unless databaseReady $
    ioError
      (userError "PostgreSQL is unavailable")

  runMigrations databasePool "migrations"

runClickHouseMigrationsApp :: IO ()
runClickHouseMigrationsApp = do
  clickHouseConfig <- loadClickHouseConfig
  clickHouse <- createClickHouseClient clickHouseConfig

  ready <- checkClickHouse clickHouse

  unless ready $
    ioError
      (userError "ClickHouse is unavailable")

  putStrLn "ClickHouse connection: OK"

  runClickHouseMigrations
    clickHouse
    "clickhouse-migrations"

runAnalyticsWorkerOnceApp :: IO ()
runAnalyticsWorkerOnceApp = do
  (databasePool, clickHouse) <-
    loadAnalyticsDependencies

  claimed <-
    runAnalyticsWorkerOnce
      databasePool
      clickHouse

  putStrLn
    ( "Analytics flush complete. Claimed="
        ++ show claimed
    )

runAnalyticsWorkerForeverApp :: IO ()
runAnalyticsWorkerForeverApp = do
  (databasePool, clickHouse) <-
    loadAnalyticsDependencies

  runAnalyticsWorkerForever
    databasePool
    clickHouse

loadAnalyticsDependencies
  :: IO (DatabasePool, ClickHouseClient)
loadAnalyticsDependencies = do
  databaseConfig <- loadDatabaseConfig
  databasePool <- createDatabasePool databaseConfig

  databaseReady <- checkDatabase databasePool

  unless databaseReady $
    ioError
      (userError "PostgreSQL is unavailable")

  clickHouseConfig <- loadClickHouseConfig
  clickHouse <- createClickHouseClient clickHouseConfig

  clickHouseReady <- checkClickHouse clickHouse

  unless clickHouseReady $
    ioError
      (userError "ClickHouse is unavailable")

  pure (databasePool, clickHouse)