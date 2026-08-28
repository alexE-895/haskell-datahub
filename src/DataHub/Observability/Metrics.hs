{-# LANGUAGE OverloadedStrings #-}

module DataHub.Observability.Metrics
  ( metricsMiddleware
  ) where

import Data.Char (isDigit)
import Data.Text (Text)
import qualified Data.Text as Text
import Network.Wai
  ( Middleware
  , Request
  , pathInfo
  )
import Network.Wai.Middleware.Prometheus
  ( PrometheusSettings (..)
  , instrumentHandlerValue
  , prometheus
  )

metricsMiddleware :: Middleware
metricsMiddleware application =
  prometheus
    settings
    ( instrumentHandlerValue
        metricHandler
        application
    )
  where
    settings =
      PrometheusSettings
        { prometheusEndPoint =
            ["metrics"]
        , prometheusInstrumentApp =
            False
        , prometheusInstrumentPrometheus =
            False
        }

metricHandler :: Request -> Text
metricHandler request =
  case pathInfo request of
    [] ->
      "/"

    segments ->
      "/"
        <> Text.intercalate
             "/"
             (map normalizeSegment segments)

normalizeSegment :: Text -> Text
normalizeSegment segment
  | isNumericIdentifier segment =
      ":id"

  | otherwise =
      segment

isNumericIdentifier :: Text -> Bool
isNumericIdentifier value =
  not (Text.null value)
    && Text.all isDigit value