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

import DataHub.Database
  ( createDatabasePool
  , loadDatabaseConfig
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

  hspec $ do
    spec (application databasePool)
    itemSpec (application databasePool)

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