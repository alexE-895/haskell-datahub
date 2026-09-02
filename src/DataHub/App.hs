module DataHub.App
  ( runAnalyticsWorkerForeverApp
  , runAnalyticsWorkerOnceApp
  , runApp
  , runClickHouseMigrationsApp
  , runMigrationsApp
  , runSyncWorkerForeverApp
  , runSyncWorkerOnceApp
  , runStorageInitApp
  , runStorageSmokeApp
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
  , loadDatabaseConfig
  , withDatabasePool
  )

import DataHub.External.GitHub
  ( GitHubClient
  , createGitHubClient
  , loadGitHubConfig
  )

import DataHub.Migrations
  ( runMigrations
  )

import DataHub.Server
  ( runServer
  )

import DataHub.Storage.Minio
  ( createStorageClient
  , ensureStorageBucket
  , loadStorageConfig
  , runStorageSmoke
  )

import DataHub.Sync.Worker
  ( runSyncWorkerForever
  , runSyncWorkerOnce
  )

runApp :: IO ()
runApp = do
  databaseConfig <-
    loadDatabaseConfig

  withDatabasePool databaseConfig $ \databasePool -> do

    databaseReady <-
      checkDatabase databasePool

    unless databaseReady $
      ioError
        (userError "PostgreSQL is unavailable during startup")

    putStrLn
      "PostgreSQL connection pool: OK"

    clickHouseConfig <-
      loadClickHouseConfig

    clickHouse <-
      createClickHouseClient clickHouseConfig

    putStrLn
      "ClickHouse analytics client: configured"

    storageConfig <-
      loadStorageConfig

    let storageClient =
          createStorageClient storageConfig

    ensureStorageBucket storageClient

    putStrLn
      "S3-compatible object storage: ready"

    runServer
      databasePool
      clickHouse
      storageClient

runMigrationsApp :: IO ()
runMigrationsApp = do
  databaseConfig <-
    loadDatabaseConfig

  withDatabasePool databaseConfig $ \databasePool -> do

    databaseReady <-
      checkDatabase databasePool

    unless databaseReady $
      ioError
        (userError "PostgreSQL is unavailable")

    runMigrations
      databasePool
      "migrations"

runClickHouseMigrationsApp :: IO ()
runClickHouseMigrationsApp = do
  clickHouseConfig <-
    loadClickHouseConfig

  clickHouse <-
    createClickHouseClient clickHouseConfig

  ready <-
    checkClickHouse clickHouse

  unless ready $
    ioError
      (userError "ClickHouse is unavailable")

  putStrLn
    "ClickHouse connection: OK"

  runClickHouseMigrations
    clickHouse
    "clickhouse-migrations"

runAnalyticsWorkerOnceApp :: IO ()
runAnalyticsWorkerOnceApp =
  withAnalyticsDependencies $ \databasePool clickHouse -> do

    claimed <-
      runAnalyticsWorkerOnce
        databasePool
        clickHouse

    putStrLn
      ( "Analytics flush complete. Claimed="
          ++ show claimed
      )

runAnalyticsWorkerForeverApp :: IO ()
runAnalyticsWorkerForeverApp =
  withAnalyticsDependencies
    runAnalyticsWorkerForever

runSyncWorkerOnceApp :: IO ()
runSyncWorkerOnceApp =
  withSyncDependencies $ \databasePool gitHub -> do

    claimed <-
      runSyncWorkerOnce
        databasePool
        gitHub

    putStrLn
      ( "Sync flush complete. Claimed="
          ++ show claimed
      )

runSyncWorkerForeverApp :: IO ()
runSyncWorkerForeverApp =
  withSyncDependencies
    runSyncWorkerForever

runStorageInitApp :: IO ()
runStorageInitApp = do
  storageConfig <-
    loadStorageConfig

  let storageClient =
        createStorageClient storageConfig

  ensureStorageBucket storageClient

runStorageSmokeApp :: IO ()
runStorageSmokeApp =
  runStorageSmoke

withAnalyticsDependencies
  :: (DatabasePool -> ClickHouseClient -> IO a)
  -> IO a
withAnalyticsDependencies action = do
  databaseConfig <-
    loadDatabaseConfig

  withDatabasePool databaseConfig $ \databasePool -> do

    databaseReady <-
      checkDatabase databasePool

    unless databaseReady $
      ioError
        (userError "PostgreSQL is unavailable")

    clickHouseConfig <-
      loadClickHouseConfig

    clickHouse <-
      createClickHouseClient clickHouseConfig

    clickHouseReady <-
      checkClickHouse clickHouse

    unless clickHouseReady $
      ioError
        (userError "ClickHouse is unavailable")

    action
      databasePool
      clickHouse

withSyncDependencies
  :: (DatabasePool -> GitHubClient -> IO a)
  -> IO a
withSyncDependencies action = do
  databaseConfig <-
    loadDatabaseConfig

  withDatabasePool databaseConfig $ \databasePool -> do

    databaseReady <-
      checkDatabase databasePool

    unless databaseReady $
      ioError
        (userError "PostgreSQL is unavailable")

    gitHubConfig <-
      loadGitHubConfig

    gitHub <-
      createGitHubClient gitHubConfig

    action
      databasePool
      gitHub