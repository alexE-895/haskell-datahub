{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

module DataHub.Sync.State
  ( NextState
  , SyncAction (..)
  , SyncJobIn
  , SyncState (..)
  , SyncTransition (..)
  , applySyncTransition
  , claimedRunningJob
  , syncJobValue
  , transitionTargetStatus
  ) where

import Data.Text (Text)

import DataHub.Sync.Types
  ( SyncJob (..)
  )

-- | Compile-time representation of the sync lifecycle.
data SyncState
  = Pending
  | Running
  | Completed
  | Failed

-- | Actions that are valid inside the lifecycle.
data SyncAction
  = ClaimAction
  | RetryAction
  | CompleteAction
  | FailAction

-- | Closed type family describing the only legal state transitions.
--
-- Invalid combinations intentionally have no equation.
-- For example there is no:
--
--   NextState 'Completed 'CompleteAction
--
-- so such a transition cannot be constructed as a valid typed operation.
type family
  NextState
    (state :: SyncState)
    (action :: SyncAction)
    :: SyncState
  where
    NextState 'Pending 'ClaimAction =
      'Running

    NextState 'Failed 'RetryAction =
      'Running

    NextState 'Running 'CompleteAction =
      'Completed

    NextState 'Running 'FailAction =
      'Failed

-- | GADT proving that a particular transition is legal.
data SyncTransition
  (state :: SyncState)
  (action :: SyncAction)
  where
    ClaimPending
      :: SyncTransition
           'Pending
           'ClaimAction

    RetryFailed
      :: SyncTransition
           'Failed
           'RetryAction

    CompleteRunning
      :: SyncTransition
           'Running
           'CompleteAction

    FailRunning
      :: SyncTransition
           'Running
           'FailAction

-- | A SyncJob carrying its state at the type level.
--
-- The state parameter is phantom at runtime but is checked by GHC.
data SyncJobIn
  (state :: SyncState)
  where
    SyncJobIn
      :: SyncJob
      -> SyncJobIn state

-- | Trusted persistence boundary.
--
-- Repository.claimSyncJobs changes the database row to "running"
-- before wrapping it with this type.
claimedRunningJob
  :: SyncJob
  -> SyncJobIn 'Running
claimedRunningJob =
  SyncJobIn

syncJobValue
  :: SyncJobIn state
  -> SyncJob
syncJobValue (SyncJobIn job) =
  job

transitionTargetStatus
  :: SyncTransition state action
  -> Text
transitionTargetStatus transition =
  case transition of
    ClaimPending ->
      "running"

    RetryFailed ->
      "running"

    CompleteRunning ->
      "completed"

    FailRunning ->
      "failed"

-- | Pure typed transition.
--
-- The result state is calculated by NextState.
applySyncTransition
  :: SyncTransition state action
  -> SyncJobIn state
  -> SyncJobIn (NextState state action)
applySyncTransition transition (SyncJobIn job) =
  SyncJobIn
    ( job
        { syncJobStatus =
            transitionTargetStatus transition
        }
    )