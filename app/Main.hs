module Main
  ( main
  ) where

import System.IO
  ( BufferMode (LineBuffering)
  , hSetBuffering
  , stderr
  , stdout
  )
import System.Environment (getArgs)
import System.Exit (die)

import DataHub.App
  ( runAnalyticsWorkerForeverApp
  , runAnalyticsWorkerOnceApp
  , runApp
  , runClickHouseMigrationsApp
  , runMigrationsApp
  , runSyncWorkerForeverApp
  , runSyncWorkerOnceApp
  , runStorageInitApp
  , runStorageSmokeApp
  )

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  arguments <-
    getArgs

  case arguments of
    [] ->
      runApp

    ["serve"] ->
      runApp

    ["migrate"] ->
      runMigrationsApp

    ["clickhouse-migrate"] ->
      runClickHouseMigrationsApp

    ["analytics-flush"] ->
      runAnalyticsWorkerOnceApp

    ["analytics-worker"] ->
      runAnalyticsWorkerForeverApp

    ["sync-flush"] ->
      runSyncWorkerOnceApp

    ["sync-worker"] ->
      runSyncWorkerForeverApp

    ["storage-init"] ->
      runStorageInitApp

    ["storage-smoke"] ->
      runStorageSmokeApp
    _ ->
      die
        "Usage: haskell-datahub [serve|migrate|clickhouse-migrate|analytics-flush|analytics-worker|sync-flush|sync-worker|storage-init|storage-smoke]"