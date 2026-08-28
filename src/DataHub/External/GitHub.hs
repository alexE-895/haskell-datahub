{-# LANGUAGE OverloadedStrings #-}

module DataHub.External.GitHub
  ( GitHubClient
  , GitHubConfig (..)
  , GitHubRepository (..)
  , createGitHubClient
  , loadGitHubConfig
  , searchRepositories
  ) where

import Data.Aeson
  ( FromJSON (parseJSON)
  , eitherDecode
  , withObject
  , (.:)
  , (.:?)
  )
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteString.Char8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Network.HTTP.Client
  ( Manager
  , Response
  , httpLbs
  , method
  , newManager
  , parseRequest
  , requestHeaders
  , responseBody
  , responseStatus
  , responseTimeout
  , responseTimeoutMicro
  , setQueryString
  )
import Network.HTTP.Client.TLS
  ( tlsManagerSettings
  )
import Network.HTTP.Types
  ( statusCode
  )
import System.Environment
  ( lookupEnv
  )

data GitHubConfig = GitHubConfig
  { gitHubApiBaseUrl :: String
  , gitHubApiVersion :: Text
  , gitHubToken :: Maybe Text
  }

data GitHubClient = GitHubClient
  { gitHubManager :: Manager
  , gitHubConfig :: GitHubConfig
  }

data GitHubRepository = GitHubRepository
  { gitHubRepositoryId :: Int64
  , gitHubRepositoryFullName :: Text
  , gitHubRepositoryDescription :: Maybe Text
  , gitHubRepositoryHtmlUrl :: Text
  , gitHubRepositoryStars :: Int
  , gitHubRepositoryLanguage :: Maybe Text
  }
  deriving (Eq, Show)

instance FromJSON GitHubRepository where
  parseJSON =
    withObject "GitHubRepository" $ \value ->
      GitHubRepository
        <$> value .: "id"
        <*> value .: "full_name"
        <*> value .:? "description"
        <*> value .: "html_url"
        <*> value .: "stargazers_count"
        <*> value .:? "language"

newtype GitHubSearchResponse =
  GitHubSearchResponse
    { gitHubSearchItems :: [GitHubRepository]
    }

instance FromJSON GitHubSearchResponse where
  parseJSON =
    withObject "GitHubSearchResponse" $ \value ->
      GitHubSearchResponse
        <$> value .: "items"

loadGitHubConfig :: IO GitHubConfig
loadGitHubConfig = do
  baseUrl <-
    fromMaybe "https://api.github.com"
      <$> lookupEnv "GITHUB_API_BASE_URL"

  apiVersion <-
    Text.pack
      . fromMaybe "2026-03-10"
      <$> lookupEnv "GITHUB_API_VERSION"

  tokenValue <-
    lookupEnv "GITHUB_TOKEN"

  let token =
        case tokenValue of
          Nothing ->
            Nothing

          Just value
            | null value ->
                Nothing

            | otherwise ->
                Just (Text.pack value)

  pure
    GitHubConfig
      { gitHubApiBaseUrl = baseUrl
      , gitHubApiVersion = apiVersion
      , gitHubToken = token
      }

createGitHubClient
  :: GitHubConfig
  -> IO GitHubClient
createGitHubClient config = do
  manager <-
    newManager tlsManagerSettings

  pure
    GitHubClient
      { gitHubManager = manager
      , gitHubConfig = config
      }

searchRepositories
  :: GitHubClient
  -> Text
  -> Int
  -> IO [GitHubRepository]
searchRepositories client searchQuery maxItems = do
  let config =
        gitHubConfig client

      baseUrl =
        dropTrailingSlash
          (gitHubApiBaseUrl config)

      url =
        baseUrl ++ "/search/repositories"

  baseRequest <-
    parseRequest url

  let standardHeaders =
        [ ( "Accept"
          , "application/vnd.github+json"
          )
        , ( "User-Agent"
          , "haskell-datahub"
          )
        , ( "X-GitHub-Api-Version"
          , Text.encodeUtf8
              (gitHubApiVersion config)
          )
        ]

      headers =
        case gitHubToken config of
          Nothing ->
            standardHeaders

          Just token ->
            ( "Authorization"
            , "Bearer " <> Text.encodeUtf8 token
            )
              : standardHeaders

      request =
        ( setQueryString
            [ ( "q"
              , Just (Text.encodeUtf8 searchQuery)
              )
            , ( "per_page"
              , Just
                  ( ByteString.Char8.pack
                      (show maxItems)
                  )
              )
            ]
            baseRequest
        )
          { method = "GET"
          , requestHeaders = headers
          , responseTimeout =
              responseTimeoutMicro
                15000000
          }

  response <-
    httpLbs
      request
      (gitHubManager client)

  ensureSuccess response

  case eitherDecode
    (responseBody response) of

    Right searchResponse ->
      pure
        (gitHubSearchItems searchResponse)

    Left decodeError ->
      ioError
        ( userError
            ( "Failed to decode GitHub response: "
                ++ decodeError
            )
        )

ensureSuccess
  :: Response LazyByteString.ByteString
  -> IO ()
ensureSuccess response = do
  let code =
        statusCode
          (responseStatus response)

  if code >= 200 && code < 300
    then pure ()

    else do
      let body =
            ByteString.Char8.unpack
              ( ByteString.take
                  2000
                  ( LazyByteString.toStrict
                      (responseBody response)
                  )
              )

      ioError
        ( userError
            ( "GitHub API request failed. HTTP "
                ++ show code
                ++ ": "
                ++ body
            )
        )

dropTrailingSlash :: String -> String
dropTrailingSlash value =
  reverse
    (dropWhile (== '/') (reverse value))