{-# LANGUAGE OverloadedStrings #-}

module DataHub.Database
  ( DatabaseConfig (..)
  , DatabasePool
  , checkDatabase
  , createDatabasePool
  , findCategoryById
  , listCategories
  , loadDatabaseConfig
  ) where

import Control.Exception (SomeException, try)
import Data.Int (Int64)
import Data.Maybe
  ( fromMaybe
  , listToMaybe
  )
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
  , query
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

type DatabasePool = Pool Connection

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

listCategories :: DatabasePool -> IO [Category]
listCategories pool =
  withResource pool $ \connection -> do
    rows <-
      query_
        connection
        "SELECT id, name, description, parent_id FROM categories ORDER BY id"
        :: IO [CategoryRow]

    pure (map unCategoryRow rows)

findCategoryById :: DatabasePool -> Int64 -> IO (Maybe Category)
findCategoryById pool categoryId =
  withResource pool $ \connection -> do
    rows <-
      query
        connection
        "SELECT id, name, description, parent_id FROM categories WHERE id = ?"
        (Only categoryId)
        :: IO [CategoryRow]

    pure (unCategoryRow <$> listToMaybe rows)