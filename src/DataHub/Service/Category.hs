module DataHub.Service.Category
  ( CategoryServiceError (..)
  , createCategory
  , deleteCategory
  , findCategoryById
  , listCategories
  , updateCategory
  ) where

import Data.Int (Int64)
import qualified Data.Text as Text

import DataHub.Database (DatabasePool)
import DataHub.Domain.Id
  ( CategoryId
  , entityIdToInt64
  )
import qualified DataHub.Repository.Category as Repository
import DataHub.Types
  ( Category
  , CreateCategoryRequest (..)
  , NewCategory (NewCategory)
  , PatchField (..)
  , UpdateCategory (UpdateCategory)
  , UpdateCategoryRequest (..)
  )

data CategoryServiceError
  = CategoryNameEmpty
  | CategoryNameTooLong
  | CategoryNameConflict
  | CategoryNotFound Int64
  | CategoryParentNotFound Int64
  | CategoryCycleDetected Int64 Int64
  | CategoryHasChildren Int64
  | CategoryUpdateEmpty
  deriving (Eq, Show)

listCategories :: DatabasePool -> IO [Category]
listCategories =
  Repository.listCategories

findCategoryById
  :: DatabasePool
  -> CategoryId
  -> IO (Maybe Category)
findCategoryById pool categoryId =
  Repository.findCategoryById
    pool
    (entityIdToInt64 categoryId)

createCategory
  :: DatabasePool
  -> CreateCategoryRequest
  -> IO (Either CategoryServiceError Category)
createCategory pool request = do
  let normalizedName =
        Text.strip (createCategoryName request)

      normalizedDescription =
        normalizeCreateDescription
          (createCategoryDescription request)

  if Text.null normalizedName
    then
      pure (Left CategoryNameEmpty)

    else
      if Text.length normalizedName > 120
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

              Left Repository.CreateCategoryNameConflict ->
                Left CategoryNameConflict

updateCategory
  :: DatabasePool
  -> CategoryId
  -> UpdateCategoryRequest
  -> IO (Either CategoryServiceError Category)
updateCategory pool categoryId request
  | isEmptyUpdate request =
      pure (Left CategoryUpdateEmpty)

  | otherwise =
      case normalizeUpdateName (requestCategoryName request) of
        Left serviceError ->
          pure (Left serviceError)

        Right normalizedName -> do
          let normalizedDescription =
                normalizeDescriptionPatch
                  (requestCategoryDescription request)

              normalizedUpdate =
                UpdateCategory
                  normalizedName
                  normalizedDescription
                  (requestCategoryParentId request)

          repositoryResult <-
            Repository.updateCategory
              pool
              (entityIdToInt64 categoryId)
              normalizedUpdate

          pure $
            case repositoryResult of
              Right category ->
                Right category

              Left (Repository.UpdateCategoryNotFound missingId) ->
                Left (CategoryNotFound missingId)

              Left (Repository.UpdateParentCategoryNotFound parentId) ->
                Left (CategoryParentNotFound parentId)

              Left
                (Repository.UpdateCategoryCycleDetected sourceId parentId) ->
                  Left
                    (CategoryCycleDetected sourceId parentId)

              Left Repository.UpdateCategoryNameConflict ->
                Left CategoryNameConflict

deleteCategory
  :: DatabasePool
  -> CategoryId
  -> IO (Either CategoryServiceError ())
deleteCategory pool categoryId = do
  repositoryResult <-
    Repository.deleteCategory
      pool
      (entityIdToInt64 categoryId)

  pure $
    case repositoryResult of
      Right () ->
        Right ()

      Left (Repository.DeleteCategoryNotFound missingId) ->
        Left (CategoryNotFound missingId)

      Left (Repository.DeleteCategoryHasChildren parentId) ->
        Left (CategoryHasChildren parentId)

isEmptyUpdate :: UpdateCategoryRequest -> Bool
isEmptyUpdate request =
  requestCategoryName request == PatchKeep
    && requestCategoryDescription request == PatchKeep
    && requestCategoryParentId request == PatchKeep

normalizeUpdateName
  :: PatchField Text.Text
  -> Either CategoryServiceError (Maybe Text.Text)
normalizeUpdateName patch =
  case patch of
    PatchKeep ->
      Right Nothing

    PatchClear ->
      Left CategoryNameEmpty

    PatchSet rawName ->
      let normalizedName =
            Text.strip rawName
       in if Text.null normalizedName
            then Left CategoryNameEmpty
            else
              if Text.length normalizedName > 120
                then Left CategoryNameTooLong
                else Right (Just normalizedName)

normalizeCreateDescription
  :: Maybe Text.Text
  -> Maybe Text.Text
normalizeCreateDescription description =
  case Text.strip <$> description of
    Just value
      | Text.null value ->
          Nothing

    other ->
      other

normalizeDescriptionPatch
  :: PatchField Text.Text
  -> PatchField Text.Text
normalizeDescriptionPatch patch =
  case patch of
    PatchKeep ->
      PatchKeep

    PatchClear ->
      PatchClear

    PatchSet rawValue ->
      let normalizedValue =
            Text.strip rawValue
       in if Text.null normalizedValue
            then PatchClear
            else PatchSet normalizedValue