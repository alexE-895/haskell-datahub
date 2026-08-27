{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module DataHub.API
  ( API
  , apiProxy
  ) where

import Data.Proxy (Proxy (Proxy))
import Servant
  ( Get
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
       "health"     :> Get '[JSON] HealthResponse
  :<|> "ready"      :> Get '[JSON] ReadinessResponse
  :<|> "categories" :> Get '[JSON] [Category]

apiProxy :: Proxy API
apiProxy = Proxy