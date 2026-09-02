{-# LANGUAGE OverloadedStrings #-}

module DataHub.Database
  ( DatabaseConfig (..)
  , DatabasePool
  , checkDatabase
  , createDatabasePool
  , withDatabasePool
  , loadDatabaseConfig
  ) where

import Control.Exception
  ( SomeException
  , bracket
  , try
  )
import Data.Maybe (fromMaybe)
import Data.Pool
  ( Pool
  , defaultPoolConfig
  , destroyAllResources
  , newPool
  , withResource
  )
import Data.Word (Word16)
import Database.PostgreSQL.Simple
  ( ConnectInfo (..)
  , Connection
  , Only (Only)
  , close
  , connect
  , defaultConnectInfo
  , query_
  )
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

import DataHub.Config
  ( loadRequiredSecret
  , loadRuntimeEnvironment
  )

data DatabaseConfig = DatabaseConfig
  { dbHost :: String
  , dbPort :: Word16
  , dbName :: String
  , dbUser :: String
  , dbPassword :: String
  }

instance Show DatabaseConfig where
  show config =
    "DatabaseConfig"
      ++ " {dbHost = "
      ++ show (dbHost config)
      ++ ", dbPort = "
      ++ show (dbPort config)
      ++ ", dbName = "
      ++ show (dbName config)
      ++ ", dbUser = "
      ++ show (dbUser config)
      ++ ", dbPassword = <redacted>}"

type DatabasePool = Pool Connection

loadDatabaseConfig :: IO DatabaseConfig
loadDatabaseConfig = do
  environment <-
    loadRuntimeEnvironment

  host <-
    fromMaybe "127.0.0.1"
      <$> lookupEnv "POSTGRES_HOST"

  portText <-
    fromMaybe "5432"
      <$> lookupEnv "POSTGRES_PORT"

  name <-
    fromMaybe "datahub"
      <$> lookupEnv "POSTGRES_DB"

  user <-
    fromMaybe "datahub"
      <$> lookupEnv "POSTGRES_USER"

  password <-
    loadRequiredSecret
      environment
      "POSTGRES_PASSWORD"
      "datahub_dev_password"

  port <-
    case readMaybe portText of
      Just value
        | value > 0 ->
            pure value

      _ ->
        ioError
          ( userError
              "POSTGRES_PORT must be an integer between 1 and 65535"
          )

  pure
    DatabaseConfig
      { dbHost = host
      , dbPort = port
      , dbName = name
      , dbUser = user
      , dbPassword = password
      }

toConnectInfo :: DatabaseConfig -> ConnectInfo
toConnectInfo config =
  defaultConnectInfo
    { connectHost = dbHost config
    , connectPort = dbPort config
    , connectDatabase = dbName config
    , connectUser = dbUser config
    , connectPassword = dbPassword config
    }

createDatabasePool :: DatabaseConfig -> IO DatabasePool
createDatabasePool config =
  newPool
    ( defaultPoolConfig
        (connect (toConnectInfo config))
        close
        60
        10
    )

withDatabasePool
  :: DatabaseConfig
  -> (DatabasePool -> IO a)
  -> IO a
withDatabasePool config action =
  bracket
    (createDatabasePool config)
    destroyAllResources
    action

checkDatabase :: DatabasePool -> IO Bool
checkDatabase pool = do
  result <-
    try
      ( withResource pool $ \connection -> do
          rows <-
            query_ connection "SELECT 1"
              :: IO [Only Int]

          pure (rows == [Only 1])
      )
      :: IO (Either SomeException Bool)

  pure
    (either (const False) id result)