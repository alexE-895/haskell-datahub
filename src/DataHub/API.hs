{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module DataHub.API
  ( API
  , apiProxy
  ) where

import Data.Proxy (Proxy (Proxy))
import Servant (Get, JSON, type (:>))

import DataHub.Types (HealthResponse)

type API =
  "health" :> Get '[JSON] HealthResponse

apiProxy :: Proxy API
apiProxy = Proxy