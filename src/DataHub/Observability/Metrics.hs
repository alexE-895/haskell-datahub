{-# LANGUAGE OverloadedStrings #-}

module DataHub.Observability.Metrics
  ( metricsMiddleware
  , metricHandler
  ) where

import Data.Text (Text)
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
    ["health"] -> "/health"
    ["ready"] -> "/ready"
    ["metrics"] -> "/metrics"
    ["categories"] -> "/categories"
    ["categories", _] -> "/categories/:id"
    ["items"] -> "/items"
    ["items", _] -> "/items/:id"
    ["files"] -> "/files"
    ["files", _] -> "/files/:id"
    ["files", _, "download"] -> "/files/:id/download"
    ["sync", "github"] -> "/sync/github"
    ["sync", "jobs", _] -> "/sync/jobs/:id"
    ["analytics", "events", "summary"] -> "/analytics/events/summary"
    ["analytics", "items", "by-source"] -> "/analytics/items/by-source"
    _ -> "/unmatched"
