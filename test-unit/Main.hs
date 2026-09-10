{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (void)
import qualified Data.ByteString as BS
import Data.IORef
import Network.HTTP.Types (status200, status413)
import Network.Wai
import Network.Wai.Internal (ResponseReceived (ResponseReceived))
import Network.Wai.Test (setPath)
import Test.Hspec

import DataHub.Observability.Metrics (metricHandler)
import DataHub.RequestLimits (maxRequestBodyBytes, requestLimitsMiddleware)
import DataHub.Server (application)

main :: IO ()
main = hspec $ do
  describe "request body bounds" $ do
    it "rejects a known oversized body before reading it" $ do
      let req = setRequestBodyChunks (error "oversized body must not be read") $ defaultRequest
            { requestBodyLength = KnownLength (maxRequestBodyBytes + 1)
            }
      void $ requestLimitsMiddleware consume req $ \res -> do
        responseStatus res `shouldBe` status413
        pure ResponseReceived

    it "stops an unknown-length stream at the first chunk over the limit" $ do
      reads <- newIORef (0 :: Int)
      let readChunk = do
                modifyIORef' reads (+ 1)
                n <- readIORef reads
                if n > 161 then error "reader continued beyond the limit"
                  else pure (BS.replicate 65536 120)
          req = setRequestBodyChunks readChunk $
            defaultRequest { requestBodyLength = ChunkedBody }
      void $ requestLimitsMiddleware consume req $ \res -> do
        responseStatus res `shouldBe` status413
        pure ResponseReceived
      readIORef reads `shouldReturn` 161

    it "accepts exactly 10 MiB" $ do
      remaining <- newIORef (160 :: Int)
      let readChunk = atomicModifyIORef' remaining $ \n ->
                (max 0 (n - 1), if n > 0 then BS.replicate 65536 120 else BS.empty)
          req = setRequestBodyChunks readChunk $
            defaultRequest { requestBodyLength = KnownLength maxRequestBodyBytes }
      void $ requestLimitsMiddleware consume req $ \res -> do
        responseStatus res `shouldBe` status200
        pure ResponseReceived

    it "bounds chunked uploads before the real Servant handler accesses storage" $ do
      reads <- newIORef (0 :: Int)
      let readChunk = do
            modifyIORef' reads (+ 1)
            n <- readIORef reads
            if n > 161 then error "Servant read beyond the limit"
              else pure (BS.replicate 65536 120)
          req = setRequestBodyChunks readChunk $ (setPath defaultRequest "/files")
            { requestMethod = "POST"
            , requestHeaders = [("Content-Type", "application/octet-stream"), ("X-File-Name", "large.bin")]
            , requestBodyLength = ChunkedBody
            }
          app = application (error "database accessed") (error "analytics accessed") (error "storage accessed")
      void $ app req $ \res -> do
        responseStatus res `shouldBe` status413
        pure ResponseReceived

  describe "bounded metric routes" $ do
    it "groups arbitrary unknown URLs together" $ do
      map (metricHandler . setPath defaultRequest)
        ["/random-a", "/random-b", "/files/1/unexpected", "/"]
        `shouldBe` replicate 4 "/unmatched"
    it "normalizes valid and malformed capture values" $ do
      map (metricHandler . setPath defaultRequest)
        ["/items/123", "/items/abc", "/items/-1"]
        `shouldBe` replicate 3 "/items/:id"
    it "preserves known static and nested routes" $ do
      map (metricHandler . setPath defaultRequest)
        ["/health", "/files/42/download", "/sync/jobs/abc", "/analytics/events/summary"]
        `shouldBe` ["/health", "/files/:id/download", "/sync/jobs/:id", "/analytics/events/summary"]

consume :: Application
consume req respond = do
  _ <- strictRequestBody req
  respond (responseLBS status200 [] "ok")
