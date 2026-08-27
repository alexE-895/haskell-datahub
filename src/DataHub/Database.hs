{-# LANGUAGE OverloadedStrings #-}

module DataHub.Database
  ( DatabaseConfig (..)
  , DatabasePool
  , checkDatabase
  , createDatabasePool
  , loadDatabaseConfig
  ) where

import Control.Exception (SomeException, try)
import Data.Maybe (fromMaybe)
import Data.Pool
  ( Pool
  , defaultPoolConfig
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

data DatabaseConfig = DatabaseConfig
  { dbHost :: String
  , dbPort :: Word16
  , dbName :: String
  , dbUser :: String
  , dbPassword :: String
  }
  deriving (Show)

type DatabasePool = Pool Connection

loadDatabaseConfig :: IO DatabaseConfig
loadDatabaseConfig = do
  host <- fromMaybe "127.0.0.1" <$> lookupEnv "POSTGRES_HOST"
  portText <- fromMaybe "5432" <$> lookupEnv "POSTGRES_PORT"
  name <- fromMaybe "datahub" <$> lookupEnv "POSTGRES_DB"
  user <- fromMaybe "datahub" <$> lookupEnv "POSTGRES_USER"
  password <- fromMaybe "datahub_dev_password" <$> lookupEnv "POSTGRES_PASSWORD"

  let port = fromMaybe 5432 (readMaybe portText)

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

checkDatabase :: DatabasePool -> IO Bool
checkDatabase pool = do
  result <-
    try
      ( withResource pool $ \connection -> do
          rows <- query_ connection "SELECT 1" :: IO [Only Int]
          pure (rows == [Only 1])
      )
      :: IO (Either SomeException Bool)

  pure (either (const False) id result)