{-# LANGUAGE OverloadedStrings #-}

module DataHub.Migrations
  ( runMigrations
  ) where

import Control.Monad
  ( forM_
  , unless
  )
import Data.List
  ( isSuffixOf
  , sort
  )
import Data.Pool (withResource)
import Data.String (fromString)
import Database.PostgreSQL.Simple
  ( Connection
  , Only (Only)
  , execute
  , execute_
  , query
  , withTransaction
  )
import System.Directory
  ( doesDirectoryExist
  , listDirectory
  )
import System.FilePath ((</>))

import DataHub.Database (DatabasePool)

runMigrations :: DatabasePool -> FilePath -> IO ()
runMigrations pool migrationsDirectory = do
  directoryExists <-
    doesDirectoryExist migrationsDirectory

  unless directoryExists $
    ioError
      ( userError
          ( "Migrations directory does not exist: "
              ++ migrationsDirectory
          )
      )

  migrationFiles <-
    sort
      . filter (".sql" `isSuffixOf`)
      <$> listDirectory migrationsDirectory

  putStrLn
    ( "Migrations directory: "
        ++ migrationsDirectory
    )

  withResource pool $ \connection -> do
    ensureMigrationTable connection

    forM_ migrationFiles $
      applyMigration
        connection
        migrationsDirectory

  putStrLn "Migrations complete."

ensureMigrationTable :: Connection -> IO ()
ensureMigrationTable connection = do
  _ <-
    execute_
      connection
      "CREATE TABLE IF NOT EXISTS schema_migrations (filename TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW())"

  pure ()

applyMigration
  :: Connection
  -> FilePath
  -> FilePath
  -> IO ()
applyMigration connection migrationsDirectory filename = do
  let migrationPath =
        migrationsDirectory </> filename

  migrationSql <-
    readFile migrationPath

  withTransaction connection $ do
    -- Serializes concurrent migration runners.
    _ <-
      execute_
        connection
        "LOCK TABLE schema_migrations IN EXCLUSIVE MODE"

    applied <-
      isMigrationApplied
        connection
        filename

    if applied
      then
        putStrLn ("SKIP  " ++ filename)

      else do
        putStrLn ("APPLY " ++ filename)

        _ <-
          execute_
            connection
            (fromString migrationSql)

        _ <-
          execute
            connection
            "INSERT INTO schema_migrations (filename) VALUES (?)"
            (Only filename)

        putStrLn ("DONE  " ++ filename)

isMigrationApplied
  :: Connection
  -> FilePath
  -> IO Bool
isMigrationApplied connection filename = do
  rows <-
    query
      connection
      "SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE filename = ?)"
      (Only filename)
      :: IO [Only Bool]

  case rows of
    [Only applied] ->
      pure applied

    _ ->
      error "schema_migrations existence query returned unexpected row count"