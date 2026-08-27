{-# LANGUAGE OverloadedStrings #-}

module DataHub.Database
  ( DatabaseConfig (..)
  , checkDatabase
  , listCategories
  , loadDatabaseConfig
  ) where

import Control.Exception (SomeException, bracket, try)
import Data.Maybe (fromMaybe)
import Data.Word (Word16)
import Database.PostgreSQL.Simple
  ( ConnectInfo (..)
  , Only (Only)
  , close
  , connect
  , defaultConnectInfo
  , query_
  )
import Database.PostgreSQL.Simple.FromRow
  ( FromRow (fromRow)
  , field
  )
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

import DataHub.Types
  ( Category (Category)
  )

data DatabaseConfig = DatabaseConfig
  { dbHost :: String
  , dbPort :: Word16
  , dbName :: String
  , dbUser :: String
  , dbPassword :: String
  }
  deriving (Show)

newtype CategoryRow = CategoryRow
  { unCategoryRow :: Category
  }

instance FromRow CategoryRow where
  fromRow =
    CategoryRow
      <$> ( Category
              <$> field
              <*> field
              <*> field
              <*> field
          )

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

checkDatabase :: DatabaseConfig -> IO Bool
checkDatabase config = do
  result <-
    try
      ( bracket
          (connect (toConnectInfo config))
          close
          (\connection -> do
              rows <- query_ connection "SELECT 1" :: IO [Only Int]
              pure (rows == [Only 1])
          )
      )
      :: IO (Either SomeException Bool)

  pure (either (const False) id result)

listCategories :: DatabaseConfig -> IO [Category]
listCategories config =
  bracket
    (connect (toConnectInfo config))
    close
    (\connection -> do
        rows <-
          query_
            connection
            "SELECT id, name, description, parent_id FROM categories ORDER BY id"
            :: IO [CategoryRow]

        pure (map unCategoryRow rows)
    )