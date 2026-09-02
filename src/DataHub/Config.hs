module DataHub.Config
  ( RuntimeEnvironment (..)
  , loadRuntimeEnvironment
  , loadRequiredSecret
  ) where

import Data.Char
  ( isSpace
  , toLower
  )
import Data.Maybe (fromMaybe)
import System.Environment (lookupEnv)

data RuntimeEnvironment
  = Development
  | Test
  | Production
  deriving (Eq, Show)

loadRuntimeEnvironment :: IO RuntimeEnvironment
loadRuntimeEnvironment = do
  raw <-
    fromMaybe "development"
      <$> lookupEnv "DATAHUB_ENV"

  case map toLower (trim raw) of
    "development" ->
      pure Development

    "dev" ->
      pure Development

    "test" ->
      pure Test

    "production" ->
      pure Production

    "prod" ->
      pure Production

    invalid ->
      ioError
        ( userError
            ( "DATAHUB_ENV must be one of: "
                ++ "development, test, production. "
                ++ "Received: "
                ++ invalid
            )
        )

loadRequiredSecret
  :: RuntimeEnvironment
  -> String
  -> String
  -> IO String
loadRequiredSecret environment variableName developmentDefault = do
  supplied <-
    lookupEnv variableName

  case fmap trim supplied of
    Just value
      | not (null value) ->
          pure value

    _
      | environment == Production ->
          ioError
            ( userError
                ( variableName
                    ++ " is required when DATAHUB_ENV=production"
                )
            )

      | otherwise ->
          pure developmentDefault

trim :: String -> String
trim =
  dropWhileEnd isSpace
    . dropWhile isSpace

dropWhileEnd
  :: (a -> Bool)
  -> [a]
  -> [a]
dropWhileEnd predicate =
  reverse
    . dropWhile predicate
    . reverse