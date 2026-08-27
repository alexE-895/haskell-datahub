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
  ( HealthResponse
  , ReadinessResponse
  )

type API =
       "health" :> Get '[JSON] HealthResponse
  :<|> "ready"  :> Get '[JSON] ReadinessResponse

apiProxy :: Proxy API
apiProxy = Proxy