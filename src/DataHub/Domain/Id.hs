{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}

module DataHub.Domain.Id
  ( CategoryId
  , EntityId
  , EntityKind
  , ItemId
  , categoryIdFromInt64
  , entityIdToInt64
  , itemIdFromInt64
  ) where

import Data.Aeson
  ( FromJSON (parseJSON)
  , ToJSON (toJSON)
  )
import Data.Int (Int64)
import qualified Web.HttpApiData as HttpApi

-- | EntityKind is promoted to a type-level kind by DataKinds.
--
-- CategoryEntity and ItemEntity are not runtime data stored inside an ID.
-- They exist only at compile time and prevent mixing unrelated identifiers.
data EntityKind
  = CategoryEntity
  | ItemEntity

-- | The 'entity' parameter is a phantom type.
--
-- Both CategoryId and ItemId contain the same Int64 at runtime,
-- but they are different types to the compiler.
newtype EntityId (entity :: EntityKind) =
  EntityId
    { unEntityId :: Int64
    }
  deriving (Eq, Ord, Show)

type CategoryId =
  EntityId 'CategoryEntity

type ItemId =
  EntityId 'ItemEntity

categoryIdFromInt64
  :: Int64
  -> CategoryId
categoryIdFromInt64 =
  EntityId

itemIdFromInt64
  :: Int64
  -> ItemId
itemIdFromInt64 =
  EntityId

entityIdToInt64
  :: EntityId entity
  -> Int64
entityIdToInt64 =
  unEntityId

-- Keep the HTTP/JSON wire format unchanged.
-- A typed ID is still represented as a JSON number and URL integer.

instance ToJSON (EntityId entity) where
  toJSON =
    toJSON . unEntityId

instance FromJSON (EntityId entity) where
  parseJSON value =
    EntityId <$> parseJSON value

instance HttpApi.ToHttpApiData (EntityId entity) where
  toUrlPiece =
    HttpApi.toUrlPiece . unEntityId

instance HttpApi.FromHttpApiData (EntityId entity) where
  parseUrlPiece value =
    case HttpApi.parseUrlPiece value of
      Left parseError ->
        Left parseError

      Right rawId ->
        Right (EntityId (rawId :: Int64))