{-# LANGUAGE OverloadedStrings #-}
-- | Mutable application state and screen definitions.
module GymTracker.AppState
  ( Screen(..)
  , AppState(..)
  , newAppState
  )
where

import Control.Concurrent.MVar (MVar, newMVar)
import Data.IORef (IORef, newIORef)
import Data.Map.Strict (Map)
import Data.Text (Text)
import GymTracker.Model (Exercise)
import Hatter.Http (HttpState)
import Hatter.Widget (Widget)

-- | Application screens.
data Screen
  = ExerciseList
  | EnterPR Exercise
  deriving (Show, Eq)

-- | Mutable application state.
data AppState = AppState
  { stScreen          :: IORef Screen
  , stRecords         :: IORef (Map Exercise Double)
  , stInputText       :: IORef Text
  , stHistory         :: IORef [(Double, Text, Maybe Text)]  -- ^ weight + timestamp + notes, newest first
  , stHttpState       :: IORef (Maybe HttpState)
  , stSyncLock        :: MVar ()
    -- ^ Held while a sync is in progress. 'tryPutMVar' guards against overlapping syncs.
  , stPercentage      :: IORef Word
    -- ^ Percentage of 1RM to calculate (0 = disabled).
  , stConfetti        :: IORef (Maybe Widget)
    -- ^ Confetti overlay widget, generated once on save so re-renders
    -- during animation don't regenerate random positions.
  , stNotesInput      :: IORef Text
    -- ^ Text input for optional notes on a PR entry.
  }

-- | Create a fresh 'AppState' with the given initial records.
newAppState :: Map Exercise Double -> IO AppState
newAppState initialRecords = do
  screen          <- newIORef ExerciseList
  records         <- newIORef initialRecords
  inputText       <- newIORef ""
  history         <- newIORef []
  httpState       <- newIORef Nothing
  syncLock        <- newMVar ()
  percentage      <- newIORef 0
  confetti        <- newIORef Nothing
  notesInput      <- newIORef ""
  pure AppState
    { stScreen          = screen
    , stRecords         = records
    , stInputText       = inputText
    , stHistory         = history
    , stHttpState       = httpState
    , stSyncLock        = syncLock
    , stPercentage      = percentage
    , stConfetti        = confetti
    , stNotesInput      = notesInput
    }
