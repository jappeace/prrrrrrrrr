{-# LANGUAGE OverloadedStrings #-}
-- | Mutable application state and screen definitions.
--
-- Split from 'GymTracker.Model' because 'AppState' depends on
-- haskell-mobile's 'HttpState', which is only available during
-- the consumer build — not in cross-deps where the persistent
-- TH schema is compiled.
module GymTracker.AppState
  ( Screen(..)
  , AppState(..)
  , newAppState
  )
where

import Data.IORef (IORef, newIORef)
import Data.Map.Strict (Map)
import Data.Text (Text)
import GymTracker.Model (Exercise)
import HaskellMobile.Http (HttpState)

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
  , stHistory         :: IORef [(Double, Text)]  -- ^ weight + timestamp, newest first
  , stHttpState       :: IORef (Maybe HttpState)
  , stNeedsSyncOnBoot :: IORef Bool
  , stPercentage      :: IORef Word
    -- ^ Percentage of 1RM to calculate (0 = disabled).
  , stConfetti        :: IORef Bool
    -- ^ Show confetti animation after saving a new PR.
  }

-- | Create a fresh 'AppState' with the given initial records.
newAppState :: Map Exercise Double -> IO AppState
newAppState initialRecords = do
  screen          <- newIORef ExerciseList
  records         <- newIORef initialRecords
  inputText       <- newIORef ""
  history         <- newIORef []
  httpState       <- newIORef Nothing
  needsSyncOnBoot <- newIORef True
  percentage      <- newIORef 0
  confetti        <- newIORef False
  pure AppState
    { stScreen          = screen
    , stRecords         = records
    , stInputText       = inputText
    , stHistory         = history
    , stHttpState       = httpState
    , stNeedsSyncOnBoot = needsSyncOnBoot
    , stPercentage      = percentage
    , stConfetti        = confetti
    }
