{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module DataHub.API
  ( API
  , apiProxy
  ) where

import Data.Int (Int64)
import Data.Proxy (Proxy (Proxy))
import Servant
  ( Capture
  , Get
  , JSON
  , type (:<|>)
  , type (:>)
  )

import DataHub.Types
  ( Category
  , HealthResponse
  , ReadinessResponse
  )

type API =
       "health" :> Get '[JSON] HealthResponse
  :<|> "ready" :> Get '[JSON] ReadinessResponse
  :<|> "categories" :> Get '[JSON] [Category]
  :<|> "categories"
        :> Capture "categoryId" Int64
        :> Get '[JSON] Category

apiProxy :: Proxy API
apiProxy = Proxy