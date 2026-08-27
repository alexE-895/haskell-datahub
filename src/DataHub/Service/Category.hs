module DataHub.Service.Category
  ( CategoryServiceError (..)
  , createCategory
  , findCategoryById
  , listCategories
  ) where

import Data.Int (Int64)
import qualified Data.Text as Text

import DataHub.Database (DatabasePool)
import qualified DataHub.Repository.Category as Repository
import DataHub.Types
  ( Category
  , CreateCategoryRequest (..)
  , NewCategory (NewCategory)
  )

data CategoryServiceError
  = CategoryNameEmpty
  | CategoryNameTooLong
  | CategoryParentNotFound Int64
  deriving (Eq, Show)

listCategories :: DatabasePool -> IO [Category]
listCategories =
  Repository.listCategories

findCategoryById :: DatabasePool -> Int64 -> IO (Maybe Category)
findCategoryById =
  Repository.findCategoryById

createCategory
  :: DatabasePool
  -> CreateCategoryRequest
  -> IO (Either CategoryServiceError Category)
createCategory pool request = do
  let normalizedName =
        Text.strip (createCategoryName request)

      normalizedDescription =
        normalizeDescription (createCategoryDescription request)

  if Text.null normalizedName
    then
      pure (Left CategoryNameEmpty)

    else if Text.length normalizedName > 120
      then
        pure (Left CategoryNameTooLong)

      else do
        repositoryResult <-
          Repository.createCategory
            pool
            ( NewCategory
                normalizedName
                normalizedDescription
                (createCategoryParentId request)
            )

        pure $
          case repositoryResult of
            Right category ->
              Right category

            Left (Repository.ParentCategoryNotFound parentId) ->
              Left (CategoryParentNotFound parentId)

normalizeDescription :: Maybe Text.Text -> Maybe Text.Text
normalizeDescription description =
  case Text.strip <$> description of
    Just value
      | Text.null value ->
          Nothing

    other ->
      other