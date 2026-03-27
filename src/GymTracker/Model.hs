{-# LANGUAGE OverloadedStrings #-}
-- | Core data model for the gym PR tracker.
module GymTracker.Model
  ( Exercise(..)
  , allExercises
  , exerciseName
  , Screen(..)
  , AppState(..)
  , newAppState
  )
where

import Data.IORef (IORef, newIORef)
import Data.Map.Strict (Map)
import Data.Text (Text)

-- | Olympic weightlifting and strength exercises.
data Exercise
  = Snatch
  | CleanAndJerk
  | Clean
  | PowerClean
  | PowerSnatch
  | FrontSquat
  | BackSquat
  | OverheadSquat
  | Deadlift
  | PushPress
  | PushJerk
  | SquatJerk
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | All exercises in enumeration order.
allExercises :: [Exercise]
allExercises = [minBound .. maxBound]

-- | Human-readable name for an exercise.
exerciseName :: Exercise -> Text
exerciseName Snatch       = "Snatch"
exerciseName CleanAndJerk = "Clean & Jerk"
exerciseName Clean        = "Clean"
exerciseName PowerClean   = "Power Clean"
exerciseName PowerSnatch  = "Power Snatch"
exerciseName FrontSquat   = "Front Squat"
exerciseName BackSquat    = "Back Squat"
exerciseName OverheadSquat = "Overhead Squat"
exerciseName Deadlift     = "Deadlift"
exerciseName PushPress    = "Push Press"
exerciseName PushJerk     = "Push Jerk"
exerciseName SquatJerk    = "Squat Jerk"

-- | Application screens.
data Screen
  = ExerciseList
  | EnterPR Exercise
  deriving (Show, Eq)

-- | Mutable application state.
data AppState = AppState
  { stScreen    :: IORef Screen
  , stRecords   :: IORef (Map Exercise Double)
  , stInputText :: IORef Text
  }

-- | Create a fresh 'AppState' with the given initial records.
newAppState :: Map Exercise Double -> IO AppState
newAppState initialRecords = do
  screen    <- newIORef ExerciseList
  records   <- newIORef initialRecords
  inputText <- newIORef ""
  pure AppState
    { stScreen    = screen
    , stRecords   = records
    , stInputText = inputText
    }
