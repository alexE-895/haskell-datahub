{-# LANGUAGE OverloadedStrings #-}

module DataHub.Storage.Service
  ( StorageServiceError (..)
  , deleteStoredFile
  , downloadStoredFile
  , findStoredFile
  , uploadStoredFile
  ) where

import Control.Exception
  ( SomeException
  , displayException
  , finally
  , try
  )

import Control.Monad
  ( when
  )

import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Char (isAlphaNum)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text

import Data.Time
  ( defaultTimeLocale
  , formatTime
  , getCurrentTime
  )

import Data.Unique
  ( hashUnique
  , newUnique
  )

import System.Directory
  ( doesFileExist
  , getTemporaryDirectory
  , removeFile
  )

import System.FilePath
  ( (</>)
  )

import DataHub.Database
  ( DatabasePool
  )

import DataHub.Storage.Minio
  ( StorageClient
  , getStorageObject
  , putStorageObject
  , removeStorageObject
  , storageBucketName
  )

import qualified DataHub.Storage.Repository as Repository

import DataHub.Storage.Types
  ( StoredFile (..)
  )

data StorageServiceError
  = StorageFileNameRequired
  | StorageFileNameTooLong
  | StorageFileTooLarge
  | StorageItemNotFound Int64
  | StorageFileNotFound Int64
  | StorageFileNotReady Text
  | StorageUnavailable
  | StoragePersistenceFailure
  deriving (Eq, Show)

maxFileSize :: Int64
maxFileSize =
  10 * 1024 * 1024

uploadStoredFile
  :: DatabasePool
  -> StorageClient
  -> Maybe Int64
  -> Maybe Text
  -> Maybe Text
  -> LazyByteString.ByteString
  -> IO (Either StorageServiceError StoredFile)
uploadStoredFile
  pool
  storage
  itemId
  suppliedName
  suppliedContentType
  bytes = do

  let fileName =
        Text.strip
          (fromMaybe "" suppliedName)

      contentType =
        let value =
              Text.strip
                ( fromMaybe
                    "application/octet-stream"
                    suppliedContentType
                )

        in
          if Text.null value
            then "application/octet-stream"
            else value

      sizeBytes =
        LazyByteString.length bytes

  if Text.null fileName
    then
      pure (Left StorageFileNameRequired)

    else if Text.length fileName > 255
      then
        pure (Left StorageFileNameTooLong)

      else if sizeBytes > maxFileSize
        then
          pure (Left StorageFileTooLarge)

        else do

          objectKey <-
            generateObjectKey fileName

          created <-
            Repository.createUploadingFile
              pool
              itemId
              (storageBucketName storage)
              objectKey
              fileName
              contentType
              sizeBytes

          case created of

            Left
              (Repository.StoredFileItemNotFound missingId) ->
                pure
                  (Left (StorageItemNotFound missingId))

            Right metadata ->
              uploadCreatedFile
                metadata
                objectKey

  where
    uploadCreatedFile metadata objectKey = do

      tempPath <-
        makeTemporaryPath
          "upload"

      let cleanup = do
            exists <-
              doesFileExist tempPath

            when exists $
              removeFile tempPath

      ( do
          LazyByteString.writeFile
            tempPath
            bytes

          uploadResult <-
            try
              ( putStorageObject
                  storage
                  objectKey
                  tempPath
              )
              :: IO (Either SomeException ())

          case uploadResult of

            Left exception -> do

              bestEffortFail
                (storedFileId metadata)
                exception

              pure
                (Left StorageUnavailable)

            Right () -> do

              readyResult <-
                try
                  ( Repository.markStoredFileReady
                      pool
                      (storedFileId metadata)
                  )
                  :: IO
                      ( Either
                          SomeException
                          (Maybe StoredFile)
                      )

              case readyResult of

                Right (Just readyFile) ->
                  pure (Right readyFile)

                _ -> do

                  _ <-
                    try
                      ( removeStorageObject
                          storage
                          objectKey
                      )
                      :: IO
                          (Either SomeException ())

                  pure
                    (Left StoragePersistenceFailure)
        )
        `finally`
          cleanup

    bestEffortFail fileId exception = do

      _ <-
        try
          ( Repository.markStoredFileFailed
              pool
              fileId
              (Text.pack (displayException exception))
          )
          :: IO (Either SomeException ())

      pure ()

findStoredFile
  :: DatabasePool
  -> Int64
  -> IO (Either StorageServiceError StoredFile)
findStoredFile pool fileId = do

  result <-
    Repository.findStoredFileById
      pool
      fileId

  pure $
    case result of

      Nothing ->
        Left
          (StorageFileNotFound fileId)

      Just file
        | storedFileStatus file == "deleted" ->
            Left
              (StorageFileNotFound fileId)

        | otherwise ->
            Right file

downloadStoredFile
  :: DatabasePool
  -> StorageClient
  -> Int64
  -> IO
      ( Either
          StorageServiceError
          (StoredFile, LazyByteString.ByteString)
      )
downloadStoredFile pool storage fileId = do

  metadataResult <-
    findStoredFile pool fileId

  case metadataResult of

    Left serviceError ->
      pure (Left serviceError)

    Right metadata
      | storedFileStatus metadata /= "ready" ->
          pure
            ( Left
                ( StorageFileNotReady
                    (storedFileStatus metadata)
                )
            )

      | otherwise -> do

          tempPath <-
            makeTemporaryPath
              "download"

          let cleanup = do
                exists <-
                  doesFileExist tempPath

                when exists $
                  removeFile tempPath

          ( do
              downloadResult <-
                try
                  ( getStorageObject
                      storage
                      (storedFileObjectKey metadata)
                      tempPath
                  )
                  :: IO
                      (Either SomeException ())

              case downloadResult of

                Left _ ->
                  pure
                    (Left StorageUnavailable)

                Right () -> do

                  strictBytes <-
                    ByteString.readFile
                      tempPath

                  let bytes =
                        LazyByteString.fromStrict
                          strictBytes

                  pure
                    (Right (metadata, bytes))
            )
            `finally`
              cleanup

deleteStoredFile
  :: DatabasePool
  -> StorageClient
  -> Int64
  -> IO (Either StorageServiceError ())
deleteStoredFile pool storage fileId = do

  existing <-
    findStoredFile pool fileId

  case existing of

    Left serviceError ->
      pure (Left serviceError)

    Right _ -> do

      deleting <-
        Repository.markStoredFileDeleting
          pool
          fileId

      case deleting of

        Nothing ->
          pure
            ( Left
                (StorageFileNotReady "invalid-state")
            )

        Just metadata -> do

          deleteResult <-
            try
              ( removeStorageObject
                  storage
                  (storedFileObjectKey metadata)
              )
              :: IO (Either SomeException ())

          case deleteResult of

            Left exception -> do

              _ <-
                try
                  ( Repository.markStoredFileFailed
                      pool
                      fileId
                      ( Text.pack
                          (displayException exception)
                      )
                  )
                  :: IO (Either SomeException ())

              pure
                (Left StorageUnavailable)

            Right () -> do

              finalResult <-
                try
                  ( Repository.markStoredFileDeleted
                      pool
                      fileId
                  )
                  :: IO (Either SomeException ())

              case finalResult of

                Left _ ->
                  pure
                    (Left StoragePersistenceFailure)

                Right () ->
                  pure (Right ())

generateObjectKey
  :: Text
  -> IO Text
generateObjectKey originalName = do

  now <-
    getCurrentTime

  unique <-
    newUnique

  let prefix =
        formatTime
          defaultTimeLocale
          "%Y/%m/%d"
          now

      stamp =
        formatTime
          defaultTimeLocale
          "%Y%m%d%H%M%S%q"
          now

      safeName =
        sanitizeFileName originalName

  pure
    ( "files/"
        <> Text.pack prefix
        <> "/"
        <> Text.pack stamp
        <> "-"
        <> Text.pack (show (hashUnique unique))
        <> "-"
        <> safeName
    )

sanitizeFileName :: Text -> Text
sanitizeFileName value =
  Text.take 160
    ( Text.map
        sanitizeCharacter
        value
    )
  where
    sanitizeCharacter character
      | isAlphaNum character =
          character

      | character `elem` ['.', '-', '_'] =
          character

      | otherwise =
          '_'

makeTemporaryPath
  :: String
  -> IO FilePath
makeTemporaryPath purpose = do

  tempDirectory <-
    getTemporaryDirectory

  now <-
    getCurrentTime

  unique <-
    newUnique

  let fileName =
        "haskell-datahub-"
          ++ purpose
          ++ "-"
          ++ formatTime
               defaultTimeLocale
               "%Y%m%d%H%M%S%q"
               now
          ++ "-"
          ++ show (hashUnique unique)
          ++ ".tmp"

  pure
    (tempDirectory </> fileName)