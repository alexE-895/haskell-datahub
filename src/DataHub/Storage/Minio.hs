{-# LANGUAGE OverloadedStrings #-}

module DataHub.Storage.Minio
  ( StorageClient
  , StorageConfig (..)
  , createStorageClient
  , ensureStorageBucket
  , getStorageObject
  , loadStorageConfig
  , putStorageObject
  , removeStorageObject
  , runStorageSmoke
  , storageBucketName
  ) where

import Control.Exception
  ( finally
  )
import Control.Monad
  ( unless
  , when
  )
import qualified Data.ByteString as ByteString
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time
  ( defaultTimeLocale
  , formatTime
  , getCurrentTime
  )
import Network.Minio
  ( ConnectInfo
  , CredentialValue (CredentialValue)
  , bucketExists
  , defaultGetObjectOptions
  , defaultPutObjectOptions
  , fGetObject
  , fPutObject
  , makeBucket
  , removeObject
  , runMinio
  , setCreds
  )
import System.Directory
  ( doesFileExist
  , removeFile
  )
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

import DataHub.Config
  ( loadRequiredSecret
  , loadRuntimeEnvironment
  )

data StorageConfig = StorageConfig
  { storageHost :: Text
  , storagePort :: Int
  , storageSecure :: Bool
  , storageAccessKey :: Text
  , storageSecretKey :: Text
  , storageBucket :: Text
  }
  deriving (Eq)

instance Show StorageConfig where
  show config =
    "StorageConfig"
      ++ " {storageHost = "
      ++ show (storageHost config)
      ++ ", storagePort = "
      ++ show (storagePort config)
      ++ ", storageSecure = "
      ++ show (storageSecure config)
      ++ ", storageAccessKey = <redacted>"
      ++ ", storageSecretKey = <redacted>"
      ++ ", storageBucket = "
      ++ show (storageBucket config)
      ++ "}"

data StorageClient = StorageClient
  { storageConnection :: ConnectInfo
  , storageBucketName :: Text
  }

loadStorageConfig :: IO StorageConfig
loadStorageConfig = do

  host <-
    Text.pack
      . fromMaybe "127.0.0.1"
      <$> lookupEnv "S3_HOST"

  portValue <-
    fromMaybe "9100"
      <$> lookupEnv "S3_PORT"

  secureValue <-
    fromMaybe "false"
      <$> lookupEnv "S3_SECURE"

  environment <-
    loadRuntimeEnvironment

  accessKey <-
    Text.pack
      <$> loadRequiredSecret
            environment
            "S3_ACCESS_KEY"
            "datahub"

  secretKey <-
    Text.pack
      <$> loadRequiredSecret
            environment
            "S3_SECRET_KEY"
            "datahub_minio_dev_password"

  bucket <-
    Text.pack
      . fromMaybe "datahub-files"
      <$> lookupEnv "S3_BUCKET"

  port <-
    case readMaybe portValue of
      Just value
        | value > 0
        , value <= 65535 ->
            pure value

      _ ->
        ioError
          ( userError
              "S3_PORT must be an integer between 1 and 65535"
          )

  secure <-
    case Text.toLower
      (Text.strip (Text.pack secureValue)) of

      "true" ->
        pure True

      "false" ->
        pure False

      _ ->
        ioError
          ( userError
              "S3_SECURE must be true or false"
          )

  pure
    StorageConfig
      { storageHost = host
      , storagePort = port
      , storageSecure = secure
      , storageAccessKey = accessKey
      , storageSecretKey = secretKey
      , storageBucket = bucket
      }

createStorageClient
  :: StorageConfig
  -> StorageClient
createStorageClient config =

  let scheme =
        if storageSecure config
          then "https://"
          else "http://"

      endpoint =
        scheme
          ++ Text.unpack
               (storageHost config)
          ++ ":"
          ++ show
               (storagePort config)

      baseConnection :: ConnectInfo
      baseConnection =
        fromString endpoint

      credentials =
        CredentialValue
          ( fromString
              ( Text.unpack
                  (storageAccessKey config)
              )
          )
          ( fromString
              ( Text.unpack
                  (storageSecretKey config)
              )
          )
          Nothing

      connection =
        setCreds
          credentials
          baseConnection

  in
    StorageClient
      { storageConnection = connection
      , storageBucketName =
          storageBucket config
      }

ensureStorageBucket
  :: StorageClient
  -> IO ()
ensureStorageBucket client = do

  result <-
    runMinio
      (storageConnection client)
      $ do

          exists <-
            bucketExists
              (storageBucketName client)

          if exists
            then
              pure False

            else do

              makeBucket
                (storageBucketName client)
                Nothing

              pure True

  case result of

    Left storageError ->
      ioError
        ( userError
            ( "S3 storage initialization failed: "
                ++ show storageError
            )
        )

    Right created ->

      if created
        then
          putStrLn
            ( "S3 bucket created: "
                ++ Text.unpack
                     (storageBucketName client)
            )

        else
          putStrLn
            ( "S3 bucket already exists: "
                ++ Text.unpack
                     (storageBucketName client)
            )

putStorageObject
  :: StorageClient
  -> Text
  -> FilePath
  -> IO ()
putStorageObject client objectKey localPath = do

  result <-
    runMinio
      (storageConnection client)
      ( fPutObject
          (storageBucketName client)
          objectKey
          localPath
          defaultPutObjectOptions
      )

  case result of

    Left storageError ->
      ioError
        ( userError
            ( "S3 upload failed: "
                ++ show storageError
            )
        )

    Right () ->
      pure ()

getStorageObject
  :: StorageClient
  -> Text
  -> FilePath
  -> IO ()
getStorageObject client objectKey localPath = do

  result <-
    runMinio
      (storageConnection client)
      ( fGetObject
          (storageBucketName client)
          objectKey
          localPath
          defaultGetObjectOptions
      )

  case result of

    Left storageError ->
      ioError
        ( userError
            ( "S3 download failed: "
                ++ show storageError
            )
        )

    Right () ->
      pure ()

removeStorageObject
  :: StorageClient
  -> Text
  -> IO ()
removeStorageObject client objectKey = do

  result <-
    runMinio
      (storageConnection client)
      ( removeObject
          (storageBucketName client)
          objectKey
      )

  case result of

    Left storageError ->
      ioError
        ( userError
            ( "S3 delete failed: "
                ++ show storageError
            )
        )

    Right () ->
      pure ()

runStorageSmoke :: IO ()
runStorageSmoke = do

  config <-
    loadStorageConfig

  let client =
        createStorageClient config

  ensureStorageBucket client

  now <-
    getCurrentTime

  let stamp =
        formatTime
          defaultTimeLocale
          "%Y%m%d%H%M%S%q"
          now

      objectKey =
        "smoke/"
          <> Text.pack stamp
          <> ".txt"

      inputPath =
        ".datahub-storage-smoke-"
          ++ stamp
          ++ "-input.tmp"

      outputPath =
        ".datahub-storage-smoke-"
          ++ stamp
          ++ "-output.tmp"

      expected =
        "haskell-datahub-storage-smoke\n"

      cleanupLocal = do

        inputExists <-
          doesFileExist inputPath

        when inputExists $
          removeFile inputPath

        outputExists <-
          doesFileExist outputPath

        when outputExists $
          removeFile outputPath

  ( do
      ByteString.writeFile
        inputPath
        expected

      putStrLn
        ( "S3 smoke upload: "
            ++ Text.unpack objectKey
        )

      putStorageObject
        client
        objectKey
        inputPath

      putStrLn
        "S3 smoke upload: OK"

      getStorageObject
        client
        objectKey
        outputPath

      putStrLn
        "S3 smoke download: OK"

      actual <-
        ByteString.readFile outputPath

      unless (actual == expected) $
        ioError
          (userError "S3 smoke content mismatch")

      putStrLn
        "S3 smoke byte comparison: OK"

      removeStorageObject
        client
        objectKey

      putStrLn
        "S3 smoke delete: OK"

      putStrLn
        "S3 STORAGE ROUND-TRIP: PASS"
    )
    `finally`
      cleanupLocal