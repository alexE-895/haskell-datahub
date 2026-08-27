{-# LANGUAGE OverloadedStrings #-}

module DataHub.Repository.Category
  ( CreateCategoryRepositoryError (..)
  , createCategory
  , findCategoryById
  , listCategories
  ) where

import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Data.Pool (withResource)
import Database.PostgreSQL.Simple
  ( Only (Only)
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
  ( Category (Category)
  , NewCategory (..)
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
createCategory pool newCategory =
  withResource pool $ \connection ->
    withTransaction connection $ do
      parentExists <-
        case newCategoryParentId newCategory of
          Nothing ->
            pure True

          Just parentId -> do
            rows <-
              query
                connection
                "SELECT id FROM categories WHERE id = ? FOR KEY SHARE"
                (Only parentId)
                :: IO [Only Int64]

            pure (not (null rows))

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