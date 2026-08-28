module Main
  ( main
  ) where

import System.Environment (getArgs)
import System.Exit (die)

import DataHub.App
  ( runApp
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

    _ ->
      die
        "Usage: haskell-datahub [serve|migrate]"