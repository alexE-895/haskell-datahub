{-# LANGUAGE OverloadedStrings #-}

module DataHub.Observability.RequestLog
  ( requestObservabilityMiddleware
  ) where

import Data.Aeson
  ( encode
  , object
  , (.=)
  )
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Time
  ( diffUTCTime
  , getCurrentTime
  )
import Data.Unique
  ( hashUnique
  , newUnique
  )
import Network.HTTP.Types
  ( statusCode
  )
import Network.Wai
  ( Middleware
  , Request
  , mapResponseHeaders
  , rawPathInfo
  , requestHeaders
  , requestMethod
  , responseStatus
  )

requestObservabilityMiddleware :: Middleware
requestObservabilityMiddleware application request respond = do
  requestId <-
    resolveRequestId request

  startedAt <-
    getCurrentTime

  let requestIdBytes =
        Text.encodeUtf8 requestId

      requestWithId =
        request
          { requestHeaders =
              ( "X-Request-ID"
              , requestIdBytes
              )
                : filter
                    ((/= "X-Request-ID") . fst)
                    (requestHeaders request)
          }

  application requestWithId $ \response -> do
    finishedAt <-
      getCurrentTime

    let durationMs =
          realToFrac
            (diffUTCTime finishedAt startedAt)
            * (1000 :: Double)

        status =
          statusCode
            (responseStatus response)

        responseWithId =
          mapResponseHeaders
            ( \headers ->
                ( "X-Request-ID"
                , requestIdBytes
                )
                  : filter
                      ((/= "X-Request-ID") . fst)
                      headers
            )
            response

    LazyByteString.putStrLn
      ( encode
          ( object
              [ "timestamp" .= finishedAt
              , "level" .= ("info" :: Text)
              , "message" .= ("http_request" :: Text)
              , "requestId" .= requestId
              , "method" .=
                  Text.decodeUtf8
                    (requestMethod request)
              , "path" .=
                  Text.decodeUtf8
                    (rawPathInfo request)
              , "status" .= status
              , "durationMs" .= durationMs
              ]
          )
      )

    respond responseWithId

resolveRequestId
  :: Request
  -> IO Text
resolveRequestId request =
  case lookup
    "X-Request-ID"
    (requestHeaders request) of

    Just supplied
      | not suppliedIsEmpty ->
          pure
            (Text.decodeUtf8 supplied)

      where
        suppliedIsEmpty =
          Text.null
            (Text.strip (Text.decodeUtf8 supplied))

    _ -> do
      unique <-
        newUnique

      pure
        ( "req-"
            <> Text.pack
                 (show (hashUnique unique))
        )