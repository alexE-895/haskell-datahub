{-# LANGUAGE OverloadedStrings #-}

module DataHub.Repository.Category
  ( CreateCategoryRepositoryError (..)
  , DeleteCategoryRepositoryError (..)
  , UpdateCategoryRepositoryError (..)
  , createCategory
  , deleteCategory
  , findCategoryById
  , listCategories
  , updateCategory
  ) where

import Control.Exception
  ( throwIO
  , try
  )
import Data.Int (Int64)
import Data.Maybe
  ( fromMaybe
  , listToMaybe
  )
import Data.Pool (withResource)
import Database.PostgreSQL.Simple
  ( Connection
  , Only (Only)
  , SqlError (..)
  , execute
  , query
  , query_
  , withTransaction
  )
import Database.PostgreSQL.Simple.FromRow
  ( FromRow (fromRow)
  , field
  )

import DataHub.Database (DatabasePool)
import DataHub.Types
  ( Category (..)
  , NewCategory (..)
  , PatchField (..)
  , UpdateCategory (..)
  )

newtype CategoryRow = CategoryRow
  { unCategoryRow :: Category
  }

instance FromRow CategoryRow where
  fromRow =
    CategoryRow
      <$> ( Category
              <$> field
              <*> field
              <*> field
              <*> field
          )

data CreateCategoryRepositoryError
  = ParentCategoryNotFound Int64
  | CreateCategoryNameConflict
  deriving (Eq, Show)

data UpdateCategoryRepositoryError
  = UpdateCategoryNotFound Int64
  | UpdateParentCategoryNotFound Int64
  | UpdateCategoryCycleDetected Int64 Int64
  | UpdateCategoryNameConflict
  deriving (Eq, Show)

data DeleteCategoryRepositoryError
  = DeleteCategoryNotFound Int64
  | DeleteCategoryHasChildren Int64
  deriving (Eq, Show)

listCategories :: DatabasePool -> IO [Category]
listCategories pool =
  withResource pool $ \connection -> do
    rows <-
      query_
        connection
        "SELECT id, name, description, parent_id FROM categories ORDER BY id"
        :: IO [CategoryRow]

    pure (map unCategoryRow rows)

findCategoryById :: DatabasePool -> Int64 -> IO (Maybe Category)
findCategoryById pool categoryId =
  withResource pool $ \connection -> do
    rows <-
      query
        connection
        "SELECT id, name, description, parent_id FROM categories WHERE id = ?"
        (Only categoryId)
        :: IO [CategoryRow]

    pure (unCategoryRow <$> listToMaybe rows)

createCategory
  :: DatabasePool
  -> NewCategory
  -> IO (Either CreateCategoryRepositoryError Category)
createCategory pool newCategory = do
  result <-
    try
      ( withResource pool $ \connection ->
          withTransaction connection $ do
            parentExists <-
              case newCategoryParentId newCategory of
                Nothing ->
                  pure True

                Just parentId ->
                  categoryExistsForShare connection parentId

            if not parentExists
              then
                case newCategoryParentId newCategory of
                  Just parentId ->
                    pure (Left (ParentCategoryNotFound parentId))

                  Nothing ->
                    error "Unexpected missing parent id"

              else do
                rows <-
                  query
                    connection
                    "INSERT INTO categories (name, description, parent_id) VALUES (?, ?, ?) RETURNING id, name, description, parent_id"
                    ( newCategoryName newCategory
                    , newCategoryDescription newCategory
                    , newCategoryParentId newCategory
                    )
                    :: IO [CategoryRow]

                case rows of
                  [CategoryRow category] ->
                    pure (Right category)

                  _ ->
                    error "INSERT categories RETURNING produced unexpected row count"
      )
      :: IO
          ( Either
              SqlError
              (Either CreateCategoryRepositoryError Category)
          )

  case result of
    Right value ->
      pure value

    Left sqlError
      | sqlState sqlError == "23505" ->
          pure (Left CreateCategoryNameConflict)

      | otherwise ->
          throwIO sqlError

updateCategory
  :: DatabasePool
  -> Int64
  -> UpdateCategory
  -> IO (Either UpdateCategoryRepositoryError Category)
updateCategory pool categoryId updateRequest = do
  result <-
    try
      ( withResource pool $ \connection ->
          withTransaction connection $
            updateInsideTransaction
              connection
              categoryId
              updateRequest
      )
      :: IO
          ( Either
              SqlError
              (Either UpdateCategoryRepositoryError Category)
          )

  case result of
    Right value ->
      pure value

    Left sqlError
      | sqlState sqlError == "23505" ->
          pure (Left UpdateCategoryNameConflict)

      | otherwise ->
          throwIO sqlError

deleteCategory
  :: DatabasePool
  -> Int64
  -> IO (Either DeleteCategoryRepositoryError ())
deleteCategory pool categoryId =
  withResource pool $ \connection ->
    withTransaction connection $ do
      targetRows <-
        query
          connection
          "SELECT id FROM categories WHERE id = ? FOR UPDATE"
          (Only categoryId)
          :: IO [Only Int64]

      if null targetRows
        then
          pure
            (Left (DeleteCategoryNotFound categoryId))

        else do
          childRows <-
            query
              connection
              "SELECT id FROM categories WHERE parent_id = ? LIMIT 1"
              (Only categoryId)
              :: IO [Only Int64]

          if not (null childRows)
            then
              pure
                (Left (DeleteCategoryHasChildren categoryId))

            else do
              deletedRows <-
                execute
                  connection
                  "DELETE FROM categories WHERE id = ?"
                  (Only categoryId)

              if deletedRows == 1
                then
                  pure (Right ())

                else
                  error "DELETE category affected unexpected row count"

updateInsideTransaction
  :: Connection
  -> Int64
  -> UpdateCategory
  -> IO (Either UpdateCategoryRepositoryError Category)
updateInsideTransaction connection categoryId updateRequest = do
  currentRows <-
    query
      connection
      "SELECT id, name, description, parent_id FROM categories WHERE id = ? FOR UPDATE"
      (Only categoryId)
      :: IO [CategoryRow]

  case listToMaybe currentRows of
    Nothing ->
      pure (Left (UpdateCategoryNotFound categoryId))

    Just (CategoryRow currentCategory) -> do
      let effectiveName =
            fromMaybe
              (categoryName currentCategory)
              (updateCategoryName updateRequest)

          effectiveDescription =
            applyNullablePatch
              (categoryDescription currentCategory)
              (updateCategoryDescription updateRequest)

          effectiveParentId =
            applyNullablePatch
              (categoryParentId currentCategory)
              (updateCategoryParentId updateRequest)

      parentResult <-
        validateParent
          connection
          categoryId
          effectiveParentId

      case parentResult of
        Left repositoryError ->
          pure (Left repositoryError)

        Right () -> do
          rows <-
            query
              connection
              "UPDATE categories SET name = ?, description = ?, parent_id = ? WHERE id = ? RETURNING id, name, description, parent_id"
              ( effectiveName
              , effectiveDescription
              , effectiveParentId
              , categoryId
              )
              :: IO [CategoryRow]

          case rows of
            [CategoryRow updatedCategory] ->
              pure (Right updatedCategory)

            _ ->
              error "UPDATE categories RETURNING produced unexpected row count"

validateParent
  :: Connection
  -> Int64
  -> Maybe Int64
  -> IO (Either UpdateCategoryRepositoryError ())
validateParent _ _ Nothing =
  pure (Right ())

validateParent connection categoryId (Just parentId)
  | parentId == categoryId =
      pure
        (Left (UpdateCategoryCycleDetected categoryId parentId))

  | otherwise = do
      parentExists <-
        categoryExistsForShare connection parentId

      if not parentExists
        then
          pure
            (Left (UpdateParentCategoryNotFound parentId))

        else do
          cycleDetected <-
            wouldCreateCycle
              connection
              categoryId
              parentId

          if cycleDetected
            then
              pure
                (Left (UpdateCategoryCycleDetected categoryId parentId))

            else
              pure (Right ())

categoryExistsForShare
  :: Connection
  -> Int64
  -> IO Bool
categoryExistsForShare connection categoryId = do
  rows <-
    query
      connection
      "SELECT id FROM categories WHERE id = ? FOR KEY SHARE"
      (Only categoryId)
      :: IO [Only Int64]

  pure (not (null rows))

wouldCreateCycle
  :: Connection
  -> Int64
  -> Int64
  -> IO Bool
wouldCreateCycle connection categoryId proposedParentId = do
  rows <-
    query
      connection
      "WITH RECURSIVE descendants(id) AS (SELECT id FROM categories WHERE parent_id = ? UNION SELECT c.id FROM categories c JOIN descendants d ON c.parent_id = d.id) SELECT EXISTS (SELECT 1 FROM descendants WHERE id = ?)"
      (categoryId, proposedParentId)
      :: IO [Only Bool]

  case rows of
    [Only result] ->
      pure result

    _ ->
      error "Cycle detection query returned unexpected row count"

applyNullablePatch
  :: Maybe a
  -> PatchField a
  -> Maybe a
applyNullablePatch currentValue patch =
  case patch of
    PatchKeep ->
      currentValue

    PatchClear ->
      Nothing

    PatchSet value ->
      Just value