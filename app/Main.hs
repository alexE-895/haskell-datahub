module Main
  ( main
  ) where

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
  )

main :: IO ()
main = do

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

    _ ->
      die
        "Usage: haskell-datahub [serve|migrate|clickhouse-migrate|analytics-flush|analytics-worker|sync-flush|sync-worker]"