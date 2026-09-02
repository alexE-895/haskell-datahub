{-# LANGUAGE OverloadedStrings #-}

module DataHub.Analytics.ClickHouse
  ( ClickHouseClient
  , ClickHouseConfig (..)
  , checkClickHouse
  , createClickHouseClient
  , insertAnalyticsEvent
  , loadClickHouseConfig
  , queryEventSummary
  , queryItemsBySource
  , runClickHouseMigrations
  ) where

import Control.Monad
  ( forM_
  , unless
  , when
  )
import Data.Aeson
  ( FromJSON
  , eitherDecodeStrict'
  , encode
  )
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteString.Char8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Int (Int64)
import Data.List
  ( isSuffixOf
  , sort
  )
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Network.HTTP.Client
  ( Manager
  , RequestBody (RequestBodyBS)
  , Response
  , applyBasicAuth
  , defaultManagerSettings
  , httpLbs
  , method
  , newManager
  , parseRequest
  , requestBody
  , responseBody
  , responseStatus
  , setQueryString
  )
import Network.HTTP.Types
  ( statusCode
  )
import System.Directory
  ( doesDirectoryExist
  , listDirectory
  )
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import Text.Read (readMaybe)

import DataHub.Config
  ( loadRequiredSecret
  , loadRuntimeEnvironment
  )

import DataHub.Analytics.Types
  ( AnalyticsEvent (..)
  , EventSummary
  , ItemSourceStat
  )

data ClickHouseConfig = ClickHouseConfig
  { clickHouseHost :: String
  , clickHousePort :: Int
  , clickHouseDatabase :: Text
  , clickHouseUser :: Text
  , clickHousePassword :: Text
  }

data ClickHouseClient = ClickHouseClient
  { clickHouseManager :: Manager
  , clickHouseConfig :: ClickHouseConfig
  }

loadClickHouseConfig :: IO ClickHouseConfig
loadClickHouseConfig = do
  host <-
    fromMaybe "127.0.0.1"
      <$> lookupEnv "CLICKHOUSE_HOST"

  portText <-
    fromMaybe "8123"
      <$> lookupEnv "CLICKHOUSE_PORT"

  database <-
    Text.pack
      . fromMaybe "datahub_analytics"
      <$> lookupEnv "CLICKHOUSE_DB"

  user <-
    Text.pack
      . fromMaybe "datahub"
      <$> lookupEnv "CLICKHOUSE_USER"

  environment <-
    loadRuntimeEnvironment

  password <-
    Text.pack
      <$> loadRequiredSecret
            environment
            "CLICKHOUSE_PASSWORD"
            "datahub_clickhouse_dev_password"

  port <-
    case readMaybe portText of
      Just value ->
        pure value

      Nothing ->
        ioError
          (userError "CLICKHOUSE_PORT must be an integer")

  pure
    ClickHouseConfig
      { clickHouseHost = host
      , clickHousePort = port
      , clickHouseDatabase = database
      , clickHouseUser = user
      , clickHousePassword = password
      }

createClickHouseClient
  :: ClickHouseConfig
  -> IO ClickHouseClient
createClickHouseClient config = do
  manager <-
    newManager defaultManagerSettings

  pure
    ClickHouseClient
      { clickHouseManager = manager
      , clickHouseConfig = config
      }

checkClickHouse
  :: ClickHouseClient
  -> IO Bool
checkClickHouse client = do
  response <-
    executeQuery client "SELECT 1"

  pure
    ( responseStatusCode response == 200
        && LazyByteString.toStrict (responseBody response)
            == "1\n"
    )

insertAnalyticsEvent
  :: ClickHouseClient
  -> AnalyticsEvent
  -> IO ()
insertAnalyticsEvent client event = do

  alreadyExists <-
    analyticsEventExists
      client
      (analyticsEventId event)

  unless alreadyExists $ do

    let body =
          ByteString.concat
            [ "INSERT INTO analytics_events FORMAT JSONEachRow\n"
            , LazyByteString.toStrict (encode event)
            , "\n"
            ]

    response <-
      executeQuery client body

    ensureSuccess
      "Failed to insert analytics event"
      response

analyticsEventExists
  :: ClickHouseClient
  -> Int64
  -> IO Bool
analyticsEventExists client eventId = do

  let queryText =
        ByteString.Char8.pack
          ( "SELECT count() FROM analytics_events "
              ++ "WHERE event_id = "
              ++ show eventId
              ++ " FORMAT TabSeparated"
          )

  response <-
    executeQuery client queryText

  ensureSuccess
    "Failed to check analytics event idempotency"
    response

  let resultText =
        ByteString.Char8.unpack
          (LazyByteString.toStrict (responseBody response))

  case readMaybe (takeWhile (/= '\n') resultText) of
    Just count ->
      pure ((count :: Int) > 0)

    Nothing ->
      ioError
        ( userError
            ( "Unexpected ClickHouse event count: "
                ++ resultText
            )
        )

queryEventSummary
  :: ClickHouseClient
  -> IO [EventSummary]
queryEventSummary client =
  queryJsonEachRow
    client
    "SELECT event_type AS eventType, entity_type AS entityType, count() AS total FROM analytics_events GROUP BY event_type, entity_type ORDER BY total DESC, entityType, eventType FORMAT JSONEachRow"

queryItemsBySource
  :: ClickHouseClient
  -> IO [ItemSourceStat]
queryItemsBySource client =
  queryJsonEachRow
    client
    "SELECT source, count() AS events, uniqExact(entity_id) AS uniqueItems FROM analytics_events WHERE entity_type = 'item' GROUP BY source ORDER BY events DESC, source FORMAT JSONEachRow"

queryJsonEachRow
  :: FromJSON a
  => ClickHouseClient
  -> ByteString.ByteString
  -> IO [a]
queryJsonEachRow client queryText = do

  response <-
    executeQuery client queryText

  ensureSuccess
    "ClickHouse analytics query failed"
    response

  let rows =
        filter
          (not . ByteString.null)
          ( ByteString.Char8.lines
              (LazyByteString.toStrict (responseBody response))
          )

  mapM decodeRow rows
  where
    decodeRow row =
      case eitherDecodeStrict' row of
        Right value ->
          pure value

        Left decodeError ->
          ioError
            ( userError
                ( "Failed to decode ClickHouse JSONEachRow: "
                    ++ decodeError
                )
            )

runClickHouseMigrations
  :: ClickHouseClient
  -> FilePath
  -> IO ()
runClickHouseMigrations client migrationsDirectory = do
  directoryExists <-
    doesDirectoryExist migrationsDirectory

  unless directoryExists $
    ioError
      ( userError
          ( "ClickHouse migrations directory does not exist: "
              ++ migrationsDirectory
          )
      )

  ensureMigrationTable client

  migrationFiles <-
    sort
      . filter (".sql" `isSuffixOf`)
      <$> listDirectory migrationsDirectory

  putStrLn
    ( "ClickHouse migrations directory: "
        ++ migrationsDirectory
    )

  forM_ migrationFiles $ \filename -> do

    applied <-
      isMigrationApplied client filename

    if applied
      then
        putStrLn ("SKIP  " ++ filename)

      else do
        putStrLn ("APPLY " ++ filename)

        migrationSql <-
          ByteString.readFile
            (migrationsDirectory </> filename)

        response <-
          executeQuery client migrationSql

        ensureSuccess
          ("ClickHouse migration failed: " ++ filename)
          response

        recordMigration client filename

        putStrLn ("DONE  " ++ filename)

  putStrLn "ClickHouse migrations complete."

ensureMigrationTable
  :: ClickHouseClient
  -> IO ()
ensureMigrationTable client = do

  response <-
    executeQuery
      client
      "CREATE TABLE IF NOT EXISTS schema_migrations (filename String, applied_at DateTime64(3, 'UTC') DEFAULT now64(3)) ENGINE = ReplacingMergeTree ORDER BY filename"

  ensureSuccess
    "Failed to create ClickHouse schema_migrations"
    response

isMigrationApplied
  :: ClickHouseClient
  -> FilePath
  -> IO Bool
isMigrationApplied client filename = do

  let escapedFilename =
        escapeSqlString filename

      queryText =
        ByteString.Char8.pack
          ( "SELECT count() FROM schema_migrations WHERE filename = '"
              ++ escapedFilename
              ++ "' FORMAT TabSeparated"
          )

  response <-
    executeQuery client queryText

  ensureSuccess
    "Failed to inspect ClickHouse schema_migrations"
    response

  let resultText =
        ByteString.Char8.unpack
          (LazyByteString.toStrict (responseBody response))

  case readMaybe (takeWhile (/= '\n') resultText) of
    Just count ->
      pure ((count :: Int) > 0)

    Nothing ->
      ioError
        ( userError
            ( "Unexpected ClickHouse migration count: "
                ++ resultText
            )
        )

recordMigration
  :: ClickHouseClient
  -> FilePath
  -> IO ()
recordMigration client filename = do

  let escapedFilename =
        escapeSqlString filename

      insertQuery =
        ByteString.Char8.pack
          ( "INSERT INTO schema_migrations (filename) VALUES ('"
              ++ escapedFilename
              ++ "')"
          )

  response <-
    executeQuery client insertQuery

  ensureSuccess
    "Failed to record ClickHouse migration"
    response

executeQuery
  :: ClickHouseClient
  -> ByteString.ByteString
  -> IO (Response LazyByteString.ByteString)
executeQuery client queryBytes = do

  let config =
        clickHouseConfig client

      baseUrl =
        "http://"
          ++ clickHouseHost config
          ++ ":"
          ++ show (clickHousePort config)
          ++ "/"

  baseRequest <-
    parseRequest baseUrl

  let requestWithOptions =
        setQueryString
          [ ( "database"
            , Just
                (Text.encodeUtf8 (clickHouseDatabase config))
            )
          , ( "date_time_input_format"
            , Just "best_effort"
            )
          ]
          baseRequest

      authenticatedRequest =
        applyBasicAuth
          (Text.encodeUtf8 (clickHouseUser config))
          (Text.encodeUtf8 (clickHousePassword config))
          requestWithOptions

      request =
        authenticatedRequest
          { method = "POST"
          , requestBody = RequestBodyBS queryBytes
          }

  httpLbs
    request
    (clickHouseManager client)

ensureSuccess
  :: String
  -> Response LazyByteString.ByteString
  -> IO ()
ensureSuccess label response = do

  let code =
        responseStatusCode response

  when (code < 200 || code >= 300) $
    ioError
      ( userError
          ( label
              ++ "\nHTTP "
              ++ show code
              ++ "\n"
              ++ ByteString.Char8.unpack
                   (LazyByteString.toStrict (responseBody response))
          )
      )

responseStatusCode
  :: Response body
  -> Int
responseStatusCode =
  statusCode . responseStatus

escapeSqlString :: String -> String
escapeSqlString =
  concatMap escapeCharacter
  where
    escapeCharacter '\'' = "''"
    escapeCharacter character = [character]