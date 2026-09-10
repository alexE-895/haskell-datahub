{-# LANGUAGE OverloadedStrings #-}

module DataHub.RequestLimits
  ( requestLimitsMiddleware
  , maxRequestBodyBytes
  ) where

import Data.Word (Word64)
import Network.HTTP.Types (status413)
import Network.Wai (Middleware, responseLBS)
import Network.Wai.Middleware.RequestSizeLimit
  ( defaultRequestSizeLimitSettings
  , requestSizeLimitMiddleware
  , setMaxLengthForRequest
  , setOnLengthExceeded
  )

maxRequestBodyBytes :: Word64
maxRequestBodyBytes = 10 * 1024 * 1024

requestLimitsMiddleware :: Middleware
requestLimitsMiddleware =
  requestSizeLimitMiddleware
    ( setOnLengthExceeded
        (\_ _ _ respond -> respond tooLarge)
        ( setMaxLengthForRequest
            (\_ -> pure (Just maxRequestBodyBytes))
            defaultRequestSizeLimitSettings
        )
    )
  where
    tooLarge = responseLBS status413
      [("Content-Type", "application/json")]
      "{\"code\":\"REQUEST_BODY_TOO_LARGE\",\"message\":\"Maximum request body size is 10 MiB\",\"details\":null}"
