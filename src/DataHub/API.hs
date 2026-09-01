{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module DataHub.API
  ( API
  , apiProxy
  ) where

import qualified Data.ByteString.Lazy as LazyByteString
import Data.Int (Int64)
import Data.Proxy (Proxy (Proxy))
import Data.Text (Text)
import Servant
  ( Capture
  , DeleteNoContent
  , Get
  , OctetStream
  , Headers
  , Header
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
import DataHub.Domain.Id
  ( CategoryId
  , ItemId
  )
import DataHub.Item.Types
  ( CreateItemRequest
  , Item
  , ItemListResponse
  , UpdateItemRequest
  )
import DataHub.Storage.Types
  ( StoredFile
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
        :> Capture "categoryId" CategoryId
        :> Get '[JSON] Category

  :<|> "categories"
        :> ReqBody '[JSON] CreateCategoryRequest
        :> PostCreated '[JSON] Category

  :<|> "categories"
        :> Capture "categoryId" CategoryId
        :> ReqBody '[JSON] UpdateCategoryRequest
        :> Patch '[JSON] Category

  :<|> "categories"
        :> Capture "categoryId" CategoryId
        :> DeleteNoContent

  :<|> "items"
        :> QueryParam "search" Text
        :> QueryParam "categoryId" CategoryId
        :> QueryParam "source" Text
        :> QueryParam "limit" Int
        :> QueryParam "offset" Int
        :> Get '[JSON] ItemListResponse

  :<|> "items"
        :> Capture "itemId" ItemId
        :> Get '[JSON] Item

  :<|> "items"
        :> ReqBody '[JSON] CreateItemRequest
        :> PostCreated '[JSON] Item

  :<|> "items"
        :> Capture "itemId" ItemId
        :> ReqBody '[JSON] UpdateItemRequest
        :> Patch '[JSON] Item

  :<|> "items"
        :> Capture "itemId" ItemId
        :> DeleteNoContent

  :<|> "sync"
        :> "github"
        :> ReqBody '[JSON] CreateGitHubSyncRequest
        :> PostCreated '[JSON] SyncJob

  :<|> "sync"
        :> "jobs"
        :> Capture "jobId" Int64
        :> Get '[JSON] SyncJob

  :<|> "files"
        :> QueryParam "itemId" Int64
        :> Header "X-File-Name" Text
        :> Header "X-Content-Type" Text
        :> ReqBody '[OctetStream] LazyByteString.ByteString
        :> PostCreated '[JSON] StoredFile

  :<|> "files"
        :> Capture "fileId" Int64
        :> Get '[JSON] StoredFile

  :<|> "files"
        :> Capture "fileId" Int64
        :> "download"
        :> Get
             '[OctetStream]
             ( Headers
                 '[ Header "Content-Disposition" Text
                  , Header "X-Original-Content-Type" Text
                  ]
                 LazyByteString.ByteString
             )

  :<|> "files"
        :> Capture "fileId" Int64
        :> DeleteNoContent

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