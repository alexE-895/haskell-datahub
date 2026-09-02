{-# LANGUAGE OverloadedStrings #-}

module Main
  ( main
  ) where

import Data.Aeson
  ( FromJSON (parseJSON)
  , ToJSON (toJSON)
  , Value
  , eitherDecode
  , encode
  , object
  , withObject
  , (.:)
  , (.:?)
  , (.=)
  )
import qualified Data.ByteString.Char8 as ByteString
import Data.Int (Int64)
import Data.Text (Text)
import Network.HTTP.Types
  ( Method
  , methodDelete
  , methodGet
  , methodPatch
  , methodPost
  , status200
  , status201
  , status204
  , status503
  , status400
  , status404
  , status409
  )
import Network.HTTP.Types.Header (hContentType)
import Network.Wai
  ( Application
  , requestHeaders
  , queryString
  , requestMethod
  )
import Network.Wai.Test
  ( SRequest (SRequest)
  , SResponse
  , defaultRequest
  , request
  , runSession
  , setPath
  , simpleBody
  , simpleStatus
  , srequest
  )
import Test.Hspec
  ( Spec
  , describe
  , hspec
  , it
  , shouldBe
  , shouldSatisfy
  )

import DataHub.Analytics.ClickHouse
  ( ClickHouseClient
  , ClickHouseConfig (ClickHouseConfig)
  , createClickHouseClient
  , loadClickHouseConfig
  )
import DataHub.Analytics.Types
  ( EventSummary (..)
  , ItemSourceStat (..)
  )
import DataHub.Analytics.Worker
  ( runAnalyticsWorkerOnce
  )
import DataHub.External.GitHub
  ( GitHubConfig (GitHubConfig)
  , createGitHubClient
  )
import DataHub.Sync.Types
  ( SyncJob (..)
  )
import DataHub.Sync.Worker
  ( runSyncWorkerOnce
  )
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import qualified Network.Wai as Wai
import Network.Wai.Handler.Warp
  ( testWithApplication
  )
import DataHub.Database
  ( DatabasePool
  , createDatabasePool
  , loadDatabaseConfig
  )
import DataHub.Storage.Minio
  ( StorageClient
  , createStorageClient
  , ensureStorageBucket
  , loadStorageConfig
  )
import DataHub.Server (application)

data CategoryResponse = CategoryResponse
  { responseCategoryId :: Int64
  , responseCategoryName :: Text
  , responseCategoryDescription :: Maybe Text
  , responseCategoryParentId :: Maybe Int64
  }
  deriving (Eq, Show)

instance FromJSON CategoryResponse where
  parseJSON =
    withObject "CategoryResponse" $ \value ->
      CategoryResponse
        <$> value .: "id"
        <*> value .: "name"
        <*> value .:? "description"
        <*> value .:? "parentId"

data ErrorResponse = ErrorResponse
  { responseErrorCode :: Text
  , responseErrorMessage :: Text
  , responseErrorDetails :: Maybe Value
  }
  deriving (Eq, Show)

instance FromJSON ErrorResponse where
  parseJSON =
    withObject "ErrorResponse" $ \value ->
      ErrorResponse
        <$> value .: "code"
        <*> value .: "message"
        <*> value .:? "details"

data CreateCategoryBody = CreateCategoryBody
  { createName :: Text
  , createDescription :: Maybe Text
  , createParentId :: Maybe Int64
  }

instance ToJSON CreateCategoryBody where
  toJSON body =
    object
      [ "name" .= createName body
      , "description" .= createDescription body
      , "parentId" .= createParentId body
      ]


data ItemTestResponse = ItemTestResponse
  { testItemId :: Int64
  , testItemCategoryId :: Int64
  , testItemName :: Text
  , testItemDescription :: Maybe Text
  , testItemSource :: Text
  , testItemExternalId :: Maybe Text
  }
  deriving (Eq, Show)

instance FromJSON ItemTestResponse where
  parseJSON =
    withObject "ItemTestResponse" $ \value ->
      ItemTestResponse
        <$> value .: "id"
        <*> value .: "categoryId"
        <*> value .: "name"
        <*> value .:? "description"
        <*> value .: "source"
        <*> value .:? "externalId"

data ItemListTestResponse = ItemListTestResponse
  { testListItems :: [ItemTestResponse]
  , testListTotal :: Int64
  , testListLimit :: Int
  , testListOffset :: Int
  }
  deriving (Eq, Show)

instance FromJSON ItemListTestResponse where
  parseJSON =
    withObject "ItemListTestResponse" $ \value ->
      ItemListTestResponse
        <$> value .: "items"
        <*> value .: "total"
        <*> value .: "limit"
        <*> value .: "offset"
main :: IO ()
main = do
  databaseConfig <- loadDatabaseConfig
  databasePool <- createDatabasePool databaseConfig
  clickHouseConfig <- loadClickHouseConfig
  clickHouse <- createClickHouseClient clickHouseConfig

  storageConfig <-

    loadStorageConfig


  let storageClient =

        createStorageClient storageConfig


  ensureStorageBucket storageClient


  hspec $ do
    spec (application databasePool clickHouse storageClient)
    itemSpec (application databasePool clickHouse storageClient)

    analyticsSpec databasePool clickHouse storageClient (application databasePool clickHouse storageClient)
    syncSpec databasePool (application databasePool clickHouse storageClient)
    storageSpec databasePool storageClient (application databasePool clickHouse storageClient)
spec :: Application -> Spec
spec app = do
  describe "health/readiness" $ do
    it "GET /health returns 200" $ do
      response <-
        getRequest app "/health"

      simpleStatus response
        `shouldBe` status200

    it "GET /ready returns 200 with test PostgreSQL available" $ do
      response <-
        getRequest app "/ready"

      simpleStatus response
        `shouldBe` status200

  describe "category API" $ do
    it "creates and reads a category" $ do
      created <-
        createCategory
          app
          "TestCreate"
          (Just "integration test")
          Nothing

      response <-
        getRequest
          app
          (categoryPath (responseCategoryId created))

      simpleStatus response
        `shouldBe` status200

      fetched <-
        decodeCategory response

      responseCategoryName fetched
        `shouldBe` "TestCreate"

    it "rejects an empty category name" $ do
      response <-
        postJson
          app
          "/categories"
          ( CreateCategoryBody
              "   "
              Nothing
              Nothing
          )

      simpleStatus response
        `shouldBe` status400

      apiError <-
        decodeError response

      responseErrorCode apiError
        `shouldBe` "CATEGORY_NAME_EMPTY"

    it "rejects case-insensitive duplicate siblings" $ do
      parent <-
        createCategory
          app
          "DuplicateRoot"
          Nothing
          Nothing

      _ <-
        createCategory
          app
          "DuplicateChild"
          Nothing
          (Just (responseCategoryId parent))

      duplicateResponse <-
        postJson
          app
          "/categories"
          ( CreateCategoryBody
              "duplicatechild"
              Nothing
              (Just (responseCategoryId parent))
          )

      simpleStatus duplicateResponse
        `shouldBe` status409

      apiError <-
        decodeError duplicateResponse

      responseErrorCode apiError
        `shouldBe` "CATEGORY_NAME_CONFLICT"

    it "updates a category with PATCH" $ do
      category <-
        createCategory
          app
          "PatchTarget"
          (Just "before")
          Nothing

      response <-
        patchJson
          app
          (categoryPath (responseCategoryId category))
          (object ["description" .= ("after" :: Text)])

      simpleStatus response
        `shouldBe` status200

      updated <-
        decodeCategory response

      responseCategoryDescription updated
        `shouldBe` Just "after"

    it "rejects hierarchy cycles" $ do
      root <-
        createCategory
          app
          "CycleRoot"
          Nothing
          Nothing

      child <-
        createCategory
          app
          "CycleChild"
          Nothing
          (Just (responseCategoryId root))

      grandChild <-
        createCategory
          app
          "CycleGrandChild"
          Nothing
          (Just (responseCategoryId child))

      response <-
        patchJson
          app
          (categoryPath (responseCategoryId root))
          ( object
              [ "parentId"
                  .= responseCategoryId grandChild
              ]
          )

      simpleStatus response
        `shouldBe` status409

      apiError <-
        decodeError response

      responseErrorCode apiError
        `shouldBe` "CATEGORY_CYCLE_DETECTED"

    it "protects parents and deletes leaf categories" $ do
      parent <-
        createCategory
          app
          "DeleteParent"
          Nothing
          Nothing

      child <-
        createCategory
          app
          "DeleteChild"
          Nothing
          (Just (responseCategoryId parent))

      parentDelete <-
        deleteRequest
          app
          (categoryPath (responseCategoryId parent))

      simpleStatus parentDelete
        `shouldBe` status409

      parentError <-
        decodeError parentDelete

      responseErrorCode parentError
        `shouldBe` "CATEGORY_HAS_CHILDREN"

      childDelete <-
        deleteRequest
          app
          (categoryPath (responseCategoryId child))

      simpleStatus childDelete
        `shouldBe` status204

      afterDelete <-
        getRequest
          app
          (categoryPath (responseCategoryId child))

      simpleStatus afterDelete
        `shouldBe` status404

    it "returns a uniform JSON error for invalid path parameters" $ do
      response <-
        getRequest app "/categories/banana"

      simpleStatus response
        `shouldBe` status400

      apiError <-
        decodeError response

      responseErrorCode apiError
        `shouldBe` "INVALID_PATH_PARAMETER"

createCategory
  :: Application
  -> Text
  -> Maybe Text
  -> Maybe Int64
  -> IO CategoryResponse
createCategory app name description parentId = do
  response <-
    postJson
      app
      "/categories"
      (CreateCategoryBody name description parentId)

  simpleStatus response
    `shouldBe` status201

  decodeCategory response

getRequest
  :: Application
  -> String
  -> IO SResponse
getRequest app path =
  runSession
    (request requestValue)
    app
  where
    requestValue =
      (setPath defaultRequest (ByteString.pack path))
        { requestMethod = methodGet
        }

deleteRequest
  :: Application
  -> String
  -> IO SResponse
deleteRequest app path =
  runSession
    (request requestValue)
    app
  where
    requestValue =
      (setPath defaultRequest (ByteString.pack path))
        { requestMethod = methodDelete
        }

postJson
  :: ToJSON a
  => Application
  -> String
  -> a
  -> IO SResponse
postJson app path body =
  jsonRequest
    app
    methodPost
    path
    body

patchJson
  :: ToJSON a
  => Application
  -> String
  -> a
  -> IO SResponse
patchJson app path body =
  jsonRequest
    app
    methodPatch
    path
    body

jsonRequest
  :: ToJSON a
  => Application
  -> Method
  -> String
  -> a
  -> IO SResponse
jsonRequest app method path body =
  runSession
    (srequest requestValue)
    app
  where
    requestValue =
      SRequest
        ( (setPath defaultRequest (ByteString.pack path))
            { requestMethod = method
            , requestHeaders =
                [(hContentType, "application/json")]
            }
        )
        (encode body)

categoryPath :: Int64 -> String
categoryPath categoryId =
  "/categories/" ++ show categoryId

decodeCategory :: SResponse -> IO CategoryResponse
decodeCategory response =
  case eitherDecode (simpleBody response) of
    Right category ->
      pure category

    Left decodeError ->
      error
        ("Failed to decode Category response: " ++ decodeError)

decodeError :: SResponse -> IO ErrorResponse
decodeError response =
  case eitherDecode (simpleBody response) of
    Right apiError ->
      pure apiError

    Left decodeError ->
      error
        ("Failed to decode ApiError response: " ++ decodeError)
itemSpec :: Application -> Spec
itemSpec app =
  describe "item API" $ do

    it "creates and reads an item" $ do
      category <-
        createCategory
          app
          "ItemCreateCategory"
          Nothing
          Nothing

      item <-
        createItemForTest
          app
          (responseCategoryId category)
          "First Item"
          (Just "created by integration test")
          (Just "manual")
          Nothing

      response <-
        getRequest
          app
          (itemPath (testItemId item))

      simpleStatus response
        `shouldBe` status200

      fetched <-
        decodeItem response

      testItemName fetched
        `shouldBe` "First Item"

    it "rejects a missing category" $ do
      response <-
        postValue
          app
          "/items"
          ( object
              [ "categoryId" .= (999999 :: Int64)
              , "name" .= ("Broken Item" :: Text)
              ]
          )

      simpleStatus response
        `shouldBe` status404

      apiError <- decodeError response

      responseErrorCode apiError
        `shouldBe` "ITEM_CATEGORY_NOT_FOUND"

    it "supports search, filters and pagination" $ do
      categoryA <-
        createCategory app "ItemSearchA" Nothing Nothing

      categoryB <-
        createCategory app "ItemSearchB" Nothing Nothing

      _ <-
        createItemForTest
          app
          (responseCategoryId categoryA)
          "Alpha GitHub"
          (Just "first alpha")
          (Just "github")
          (Just "gh-1")

      _ <-
        createItemForTest
          app
          (responseCategoryId categoryA)
          "Beta GitHub"
          Nothing
          (Just "github")
          (Just "gh-2")

      _ <-
        createItemForTest
          app
          (responseCategoryId categoryB)
          "Alpha Manual"
          Nothing
          (Just "manual")
          Nothing

      response <-
        getRequestWithQuery
          app
          "/items"
          [ ("search", Just "alpha")
          , ( "categoryId"
            , Just
                ( ByteString.pack
                    (show (responseCategoryId categoryA))
                )
            )
          , ("source", Just "github")
          , ("limit", Just "10")
          , ("offset", Just "0")
          ]

      simpleStatus response
        `shouldBe` status200

      result <-
        decodeItemList response

      testListTotal result
        `shouldBe` 1

      length (testListItems result)
        `shouldBe` 1

      case testListItems result of
        [item] ->
          testItemName item
            `shouldBe` "Alpha GitHub"

        unexpectedItems ->
          error
            ( "Expected exactly one filtered item, got: "
                ++ show unexpectedItems
            )

    it "updates an item" $ do
      category <-
        createCategory app "ItemPatchCategory" Nothing Nothing

      item <-
        createItemForTest
          app
          (responseCategoryId category)
          "Patch Item"
          (Just "before")
          (Just "manual")
          Nothing

      response <-
        patchJson
          app
          (itemPath (testItemId item))
          ( object
              [ "description" .= ("after" :: Text)
              , "source" .= ("sync" :: Text)
              , "externalId" .= ("ext-100" :: Text)
              ]
          )

      simpleStatus response
        `shouldBe` status200

      updated <- decodeItem response

      testItemDescription updated
        `shouldBe` Just "after"

      testItemSource updated
        `shouldBe` "sync"

      testItemExternalId updated
        `shouldBe` Just "ext-100"

    it "rejects duplicate item names inside one category" $ do
      category <-
        createCategory app "ItemConflictCategory" Nothing Nothing

      _ <-
        createItemForTest
          app
          (responseCategoryId category)
          "Unique Item"
          Nothing
          Nothing
          Nothing

      response <-
        postValue
          app
          "/items"
          ( object
              [ "categoryId" .= responseCategoryId category
              , "name" .= ("unique item" :: Text)
              ]
          )

      simpleStatus response
        `shouldBe` status409

      apiError <- decodeError response

      responseErrorCode apiError
        `shouldBe` "ITEM_CONFLICT"

    it "validates pagination" $ do
      response <-
        getRequestWithQuery
          app
          "/items"
          [("limit", Just "101")]

      simpleStatus response
        `shouldBe` status400

      apiError <- decodeError response

      responseErrorCode apiError
        `shouldBe` "ITEM_LIMIT_INVALID"

    it "supports keyset pagination with afterId" $ do
      category <-
        createCategory
          app
          "ItemCursorCategory"
          Nothing
          Nothing

      first <-
        createItemForTest
          app
          (responseCategoryId category)
          "Cursor Item 1"
          Nothing
          Nothing
          Nothing

      second <-
        createItemForTest
          app
          (responseCategoryId category)
          "Cursor Item 2"
          Nothing
          Nothing
          Nothing

      third <-
        createItemForTest
          app
          (responseCategoryId category)
          "Cursor Item 3"
          Nothing
          Nothing
          Nothing

      firstPageResponse <-
        getRequestWithQuery
          app
          "/items"
          [ ( "categoryId"
            , Just
                ( ByteString.pack
                    (show (responseCategoryId category))
                )
            )
          , ("limit", Just "2")
          ]

      simpleStatus firstPageResponse
        `shouldBe` status200

      firstPage <-
        decodeItemList firstPageResponse

      map testItemId (testListItems firstPage)
        `shouldBe`
          [ testItemId first
          , testItemId second
          ]

      secondPageResponse <-
        getRequestWithQuery
          app
          "/items"
          [ ( "categoryId"
            , Just
                ( ByteString.pack
                    (show (responseCategoryId category))
                )
            )
          , ("limit", Just "2")
          , ( "afterId"
            , Just
                ( ByteString.pack
                    (show (testItemId second))
                )
            )
          ]

      simpleStatus secondPageResponse
        `shouldBe` status200

      secondPage <-
        decodeItemList secondPageResponse

      map testItemId (testListItems secondPage)
        `shouldBe` [testItemId third]

      testListTotal secondPage
        `shouldBe` 3

    it "rejects afterId with non-zero offset" $ do
      response <-
        getRequestWithQuery
          app
          "/items"
          [ ("afterId", Just "1")
          , ("offset", Just "1")
          ]

      simpleStatus response
        `shouldBe` status400

      apiError <-
        decodeError response

      responseErrorCode apiError
        `shouldBe` "ITEM_PAGINATION_MODE_CONFLICT"
    it "deletes an item" $ do
      category <-
        createCategory app "ItemDeleteCategory" Nothing Nothing

      item <-
        createItemForTest
          app
          (responseCategoryId category)
          "Delete Item"
          Nothing
          Nothing
          Nothing

      deleted <-
        deleteRequest
          app
          (itemPath (testItemId item))

      simpleStatus deleted
        `shouldBe` status204

      afterDelete <-
        getRequest
          app
          (itemPath (testItemId item))

      simpleStatus afterDelete
        `shouldBe` status404

createItemForTest
  :: Application
  -> Int64
  -> Text
  -> Maybe Text
  -> Maybe Text
  -> Maybe Text
  -> IO ItemTestResponse
createItemForTest app categoryId name description source externalId = do
  response <-
    postValue
      app
      "/items"
      ( object
          [ "categoryId" .= categoryId
          , "name" .= name
          , "description" .= description
          , "source" .= source
          , "externalId" .= externalId
          ]
      )

  simpleStatus response
    `shouldBe` status201

  decodeItem response

postValue
  :: Application
  -> String
  -> Value
  -> IO SResponse
postValue =
  postJson

getRequestWithQuery
  :: Application
  -> String
  -> [(ByteString.ByteString, Maybe ByteString.ByteString)]
  -> IO SResponse
getRequestWithQuery app path queryParameters =
  runSession
    (request requestValue)
    app
  where
    requestValue =
      (setPath defaultRequest (ByteString.pack path))
        { requestMethod = methodGet
        , queryString = queryParameters
        }

itemPath :: Int64 -> String
itemPath itemId =
  "/items/" ++ show itemId

decodeItem :: SResponse -> IO ItemTestResponse
decodeItem response =
  case eitherDecode (simpleBody response) of
    Right item ->
      pure item

    Left decodeFailure ->
      error
        ("Failed to decode Item response: " ++ decodeFailure)

decodeItemList :: SResponse -> IO ItemListTestResponse
decodeItemList response =
  case eitherDecode (simpleBody response) of
    Right result ->
      pure result

    Left decodeFailure ->
      error
        ("Failed to decode ItemList response: " ++ decodeFailure)

data StoredFileTestResponse = StoredFileTestResponse
  { storedFileTestId :: Int64
  , storedFileTestStatus :: Text
  }
  deriving (Eq, Show)

instance FromJSON StoredFileTestResponse where
  parseJSON =
    withObject "StoredFileTestResponse" $ \objectValue ->
      StoredFileTestResponse
        <$> objectValue .: "id"
        <*> objectValue .: "status"


decodeStoredFile
  :: SResponse
  -> IO StoredFileTestResponse
decodeStoredFile response =
  case eitherDecode (simpleBody response) of

    Right storedFile ->
      pure storedFile

    Left decodeFailure ->
      error
        ( "Failed to decode StoredFile response: "
            ++ decodeFailure
        )


storageSpec
  :: DatabasePool
  -> StorageClient
  -> Application
  -> Spec
storageSpec _databasePool _storageClient app =
  describe "Storage API" $ do

    it "uploads and downloads exactly the same bytes" $ do

      let payload =
            "haskell-datahub-storage-integration-test"

          uploadRequest =
            SRequest
              ( (setPath defaultRequest (ByteString.pack "/files"))
                  { requestMethod = methodPost
                  , requestHeaders =
                      [ (hContentType, "application/octet-stream")
                      , ("X-File-Name", "integration-test.txt")
                      , ("X-Content-Type", "text/plain")
                      ]
                  }
              )
              payload

      uploadResponse <-
        runSession
          (srequest uploadRequest)
          app

      simpleStatus uploadResponse
        `shouldBe` status201

      uploaded <-
        decodeStoredFile uploadResponse

      storedFileTestStatus uploaded
        `shouldBe` "ready"

      let fileId =
            storedFileTestId uploaded

          filePath =
            "/files/" ++ show fileId

          downloadPath =
            filePath ++ "/download"

      downloadResponse <-
        getRequest
          app
          downloadPath

      simpleStatus downloadResponse
        `shouldBe` status200

      simpleBody downloadResponse
        `shouldBe` payload

      cleanupResponse <-
        deleteRequest
          app
          filePath

      simpleStatus cleanupResponse
        `shouldBe` status204


    it "rejects upload without X-File-Name" $ do

      let invalidRequest =
            SRequest
              ( (setPath defaultRequest (ByteString.pack "/files"))
                  { requestMethod = methodPost
                  , requestHeaders =
                      [ (hContentType, "application/octet-stream")
                      ]
                  }
              )
              "invalid-upload"

      response <-
        runSession
          (srequest invalidRequest)
          app

      simpleStatus response
        `shouldBe` status400

      apiError <-
        decodeError response

      responseErrorCode apiError
        `shouldBe` "FILE_NAME_REQUIRED"


    it "deletes a stored file and hides it from the API" $ do

      let payload =
            "delete-me"

          uploadRequest =
            SRequest
              ( (setPath defaultRequest (ByteString.pack "/files"))
                  { requestMethod = methodPost
                  , requestHeaders =
                      [ (hContentType, "application/octet-stream")
                      , ("X-File-Name", "delete-test.txt")
                      , ("X-Content-Type", "text/plain")
                      ]
                  }
              )
              payload

      uploadResponse <-
        runSession
          (srequest uploadRequest)
          app

      simpleStatus uploadResponse
        `shouldBe` status201

      uploaded <-
        decodeStoredFile uploadResponse

      storedFileTestStatus uploaded
        `shouldBe` "ready"

      let fileId =
            storedFileTestId uploaded

          filePath =
            "/files/" ++ show fileId

      deleteResponse <-
        deleteRequest
          app
          filePath

      simpleStatus deleteResponse
        `shouldBe` status204

      afterDelete <-
        getRequest
          app
          filePath

      simpleStatus afterDelete
        `shouldBe` status404

      apiError <-
        decodeError afterDelete

      responseErrorCode apiError
        `shouldBe` "FILE_NOT_FOUND"

analyticsSpec
  :: DatabasePool
  -> ClickHouseClient
  -> StorageClient
  -> Application
  -> Spec
analyticsSpec databasePool clickHouse storageClient app =
  describe "analytics API" $ do

    it "delivers transactional outbox events to ClickHouse" $ do
      category <-
        createCategory
          app
          "AnalyticsCategory"
          Nothing
          Nothing

      _ <-
        createItemForTest
          app
          (responseCategoryId category)
          "Analytics Item"
          (Just "analytics integration test")
          (Just "integration")
          (Just "analytics-item-1")

      claimed <-
        runAnalyticsWorkerOnce
          databasePool
          clickHouse

      (claimed > 0)
        `shouldBe` True

      summaryResponse <-
        getRequest
          app
          "/analytics/events/summary"

      simpleStatus summaryResponse
        `shouldBe` status200

      summaries <-
        decodeEventSummaries summaryResponse

      any
        (\summary ->
            eventSummaryEventType summary == "item_created"
              && eventSummaryEntityType summary == "item"
              && eventSummaryTotal summary >= 1
        )
        summaries
        `shouldBe` True

      sourceResponse <-
        getRequest
          app
          "/analytics/items/by-source"

      simpleStatus sourceResponse
        `shouldBe` status200

      sourceStats <-
        decodeItemSourceStats sourceResponse

      any
        (\stat ->
            itemSourceStatSource stat == "integration"
              && itemSourceStatEvents stat >= 1
              && itemSourceStatUniqueItems stat >= 1
        )
        sourceStats
        `shouldBe` True

    it "keeps core API available when ClickHouse is unavailable" $ do
      unavailableClickHouse <-
        createClickHouseClient
          ( ClickHouseConfig
              "127.0.0.1"
              65534
              "unavailable"
              "invalid"
              "invalid"
          )

      let unavailableApp =
            application databasePool unavailableClickHouse storageClient

      coreResponse <-
        getRequest
          unavailableApp
          "/items"

      simpleStatus coreResponse
        `shouldBe` status200

      analyticsResponse <-
        getRequest
          unavailableApp
          "/analytics/events/summary"

      simpleStatus analyticsResponse
        `shouldBe` status503

      apiError <-
        decodeError analyticsResponse

      responseErrorCode apiError
        `shouldBe` "ANALYTICS_UNAVAILABLE"

decodeEventSummaries
  :: SResponse
  -> IO [EventSummary]
decodeEventSummaries response =
  case eitherDecode (simpleBody response) of
    Right summaries ->
      pure summaries

    Left decodeFailure ->
      error
        ( "Failed to decode EventSummary response: "
            ++ decodeFailure
        )

decodeItemSourceStats
  :: SResponse
  -> IO [ItemSourceStat]
decodeItemSourceStats response =
  case eitherDecode (simpleBody response) of
    Right stats ->
      pure stats

    Left decodeFailure ->
      error
        ( "Failed to decode ItemSourceStat response: "
            ++ decodeFailure
        )
syncSpec
  :: DatabasePool
  -> Application
  -> Spec
syncSpec databasePool app =
  describe "external sync API" $ do

    it "imports GitHub repositories through a local mock API" $ do

      category <-
        createCategory
          app
          "MockGitHubCategory"
          Nothing
          Nothing

      createResponse <-
        postJson
          app
          "/sync/github"
          ( object
              [ "query" .= ("language:haskell" :: Text)
              , "categoryId" .= responseCategoryId category
              , "maxItems" .= (2 :: Int)
              ]
          )

      simpleStatus createResponse
        `shouldBe` status201

      createdJob <-
        decodeSyncJob createResponse

      syncJobStatus createdJob
        `shouldBe` "pending"

      syncJobResultCount createdJob
        `shouldBe` 0

      testWithApplication
        (pure mockGitHubApplication)
        $ \port -> do

          gitHub <-
            createGitHubClient
              ( GitHubConfig
                  ( "http://127.0.0.1:"
                      ++ show port
                  )
                  "2026-03-10"
                  Nothing
              )

          claimed <-
            runSyncWorkerOnce
              databasePool
              gitHub

          claimed
            `shouldBe` 1

      jobResponse <-
        getRequest
          app
          ( "/sync/jobs/"
              ++ show (syncJobId createdJob)
          )

      simpleStatus jobResponse
        `shouldBe` status200

      completedJob <-
        decodeSyncJob jobResponse

      syncJobStatus completedJob
        `shouldBe` "completed"

      syncJobAttempts completedJob
        `shouldBe` 0

      syncJobResultCount completedJob
        `shouldBe` 2

      itemsResponse <-
        getRequestWithQuery
          app
          "/items"
          [ ("source", Just "github")
          , ("limit", Just "100")
          ]

      simpleStatus itemsResponse
        `shouldBe` status200

      itemList <-
        decodeItemList itemsResponse

      let names =
            map
              testItemName
              (testListItems itemList)

      ("mock-owner/mock-repo-a" `elem` names)
        `shouldBe` True

      ("mock-owner/mock-repo-b" `elem` names)
        `shouldBe` True

    it "validates sync REST requests" $ do

      category <-
        createCategory
          app
          "SyncValidationCategory"
          Nothing
          Nothing

      emptyQueryResponse <-
        postJson
          app
          "/sync/github"
          ( object
              [ "query" .= ("   " :: Text)
              , "categoryId" .= responseCategoryId category
              , "maxItems" .= (2 :: Int)
              ]
          )

      simpleStatus emptyQueryResponse
        `shouldBe` status400

      emptyQueryError <-
        decodeError emptyQueryResponse

      responseErrorCode emptyQueryError
        `shouldBe` "SYNC_QUERY_EMPTY"

      invalidLimitResponse <-
        postJson
          app
          "/sync/github"
          ( object
              [ "query" .= ("haskell" :: Text)
              , "categoryId" .= responseCategoryId category
              , "maxItems" .= (101 :: Int)
              ]
          )

      simpleStatus invalidLimitResponse
        `shouldBe` status400

      invalidLimitError <-
        decodeError invalidLimitResponse

      responseErrorCode invalidLimitError
        `shouldBe` "SYNC_MAX_ITEMS_INVALID"

      missingCategoryResponse <-
        postJson
          app
          "/sync/github"
          ( object
              [ "query" .= ("haskell" :: Text)
              , "categoryId" .= (999999 :: Int64)
              , "maxItems" .= (2 :: Int)
              ]
          )

      simpleStatus missingCategoryResponse
        `shouldBe` status404

      missingCategoryError <-
        decodeError missingCategoryResponse

      responseErrorCode missingCategoryError
        `shouldBe` "SYNC_CATEGORY_NOT_FOUND"

    it "marks a sync job failed when the external API is unavailable" $ do

      category <-
        createCategory
          app
          "SyncFailureCategory"
          Nothing
          Nothing

      createResponse <-
        postJson
          app
          "/sync/github"
          ( object
              [ "query" .= ("mock-failure" :: Text)
              , "categoryId" .= responseCategoryId category
              , "maxItems" .= (1 :: Int)
              ]
          )

      simpleStatus createResponse
        `shouldBe` status201

      createdJob <-
        decodeSyncJob createResponse

      unavailableGitHub <-
        createGitHubClient
          ( GitHubConfig
              "http://127.0.0.1:65533"
              "2026-03-10"
              Nothing
          )

      claimed <-
        runSyncWorkerOnce
          databasePool
          unavailableGitHub

      claimed
        `shouldBe` 1

      jobResponse <-
        getRequest
          app
          ( "/sync/jobs/"
              ++ show (syncJobId createdJob)
          )

      simpleStatus jobResponse
        `shouldBe` status200

      failedJob <-
        decodeSyncJob jobResponse

      syncJobStatus failedJob
        `shouldBe` "failed"

      syncJobAttempts failedJob
        `shouldBe` 1

      (syncJobLastError failedJob == Nothing)
        `shouldBe` False

mockGitHubApplication :: Application
mockGitHubApplication _ respond =
  respond
    ( Wai.responseLBS
        status200
        [ ("Content-Type", "application/json") ]
        ( LazyByteString.pack
            "{\"total_count\":2,\"incomplete_results\":false,\"items\":[{\"id\":900001,\"full_name\":\"mock-owner/mock-repo-a\",\"description\":\"Mock repository A\",\"html_url\":\"https://example.invalid/mock-a\",\"stargazers_count\":12345,\"language\":\"Haskell\"},{\"id\":900002,\"full_name\":\"mock-owner/mock-repo-b\",\"description\":\"Mock repository B\",\"html_url\":\"https://example.invalid/mock-b\",\"stargazers_count\":6789,\"language\":\"Haskell\"}]}"
        )
    )

decodeSyncJob
  :: SResponse
  -> IO SyncJob
decodeSyncJob response =
  case eitherDecode (simpleBody response) of
    Right job ->
      pure job

    Left decodeFailure ->
      error
        ( "Failed to decode SyncJob response: "
            ++ decodeFailure
        )