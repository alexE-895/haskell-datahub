{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module DataHub.API
  ( API
  , apiProxy
  ) where

import Data.Int (Int64)
import Data.Proxy (Proxy (Proxy))
import Data.Text (Text)
import Servant
  ( Capture
  , DeleteNoContent
  , Get
  , JSON
  , Patch
  , PostCreated
  , QueryParam
  , ReqBody
  , type (:<|>)
  , type (:>)
  )

import DataHub.Analytics.Types
  ( EventSummary
  , ItemSourceStat
  )
import DataHub.Item.Types
  ( CreateItemRequest
  , Item
  , ItemListResponse
  , UpdateItemRequest
  )
import DataHub.Sync.Types
  ( CreateGitHubSyncRequest
  , SyncJob
  )
import DataHub.Types
  ( Category
  , CreateCategoryRequest
  , HealthResponse
  , ReadinessResponse
  , UpdateCategoryRequest
  )

type API =
       "health"
        :> Get '[JSON] HealthResponse

  :<|> "ready"
        :> Get '[JSON] ReadinessResponse

  :<|> "categories"
        :> Get '[JSON] [Category]

  :<|> "categories"
        :> Capture "categoryId" Int64
        :> Get '[JSON] Category

  :<|> "categories"
        :> ReqBody '[JSON] CreateCategoryRequest
        :> PostCreated '[JSON] Category

  :<|> "categories"
        :> Capture "categoryId" Int64
        :> ReqBody '[JSON] UpdateCategoryRequest
        :> Patch '[JSON] Category

  :<|> "categories"
        :> Capture "categoryId" Int64
        :> DeleteNoContent

  :<|> "items"
        :> QueryParam "search" Text
        :> QueryParam "categoryId" Int64
        :> QueryParam "source" Text
        :> QueryParam "limit" Int
        :> QueryParam "offset" Int
        :> Get '[JSON] ItemListResponse

  :<|> "items"
        :> Capture "itemId" Int64
        :> Get '[JSON] Item

  :<|> "items"
        :> ReqBody '[JSON] CreateItemRequest
        :> PostCreated '[JSON] Item

  :<|> "items"
        :> Capture "itemId" Int64
        :> ReqBody '[JSON] UpdateItemRequest
        :> Patch '[JSON] Item

  :<|> "items"
        :> Capture "itemId" Int64
        :> DeleteNoContent

  :<|> "sync"
        :> "github"
        :> ReqBody '[JSON] CreateGitHubSyncRequest
        :> PostCreated '[JSON] SyncJob

  :<|> "sync"
        :> "jobs"
        :> Capture "jobId" Int64
        :> Get '[JSON] SyncJob

  :<|> "analytics"
        :> "events"
        :> "summary"
        :> Get '[JSON] [EventSummary]

  :<|> "analytics"
        :> "items"
        :> "by-source"
        :> Get '[JSON] [ItemSourceStat]

apiProxy :: Proxy API
apiProxy = Proxy