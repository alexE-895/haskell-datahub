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
  )

main :: IO ()
main = do
  arguments <- getArgs

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

    _ ->
      die
        "Usage: haskell-datahub [serve|migrate|clickhouse-migrate|analytics-flush|analytics-worker]"