{-# LANGUAGE OverloadedStrings #-}
-- | Core exercise model for the gym PR tracker.
--
-- This module lives in the schema package so that the persistent TH
-- definitions in 'GymTracker.Schema' can reference the 'Exercise' type
-- without pulling in haskell-mobile (which is only available in the
-- consumer build, not in cross-deps).
module GymTracker.Model
  ( Exercise(..)
  , allExercises
  , exerciseName
  , parseExercise
  , ExerciseCategory(..)
  , allCategories
  , categoryName
  , exerciseCategory
  )
where

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
exerciseName Snatch        = "Snatch"
exerciseName CleanAndJerk  = "Clean & Jerk"
exerciseName Clean         = "Clean"
exerciseName PowerClean    = "Power Clean"
exerciseName PowerSnatch   = "Power Snatch"
exerciseName FrontSquat    = "Front Squat"
exerciseName BackSquat     = "Back Squat"
exerciseName OverheadSquat = "Overhead Squat"
exerciseName Deadlift      = "Deadlift"
exerciseName PushPress     = "Push Press"
exerciseName PushJerk      = "Push Jerk"
exerciseName SquatJerk     = "Squat Jerk"

-- | Grouping categories for the exercise list screen.
data ExerciseCategory
  = Snatches
  | Cleans
  | JerksAndPresses
  | Squats
  | Pulls
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | All categories in enumeration order.
allCategories :: [ExerciseCategory]
allCategories = [minBound .. maxBound]

-- | Human-readable name for a category.
categoryName :: ExerciseCategory -> Text
categoryName Snatches        = "Snatches"
categoryName Cleans          = "Cleans"
categoryName JerksAndPresses = "Jerks & Presses"
categoryName Squats          = "Squats"
categoryName Pulls           = "Pulls"

-- | The category an exercise belongs to.
exerciseCategory :: Exercise -> ExerciseCategory
exerciseCategory Snatch        = Snatches
exerciseCategory PowerSnatch   = Snatches
exerciseCategory Clean         = Cleans
exerciseCategory PowerClean    = Cleans
exerciseCategory CleanAndJerk  = Cleans
exerciseCategory PushPress     = JerksAndPresses
exerciseCategory PushJerk      = JerksAndPresses
exerciseCategory SquatJerk     = JerksAndPresses
exerciseCategory FrontSquat    = Squats
exerciseCategory BackSquat     = Squats
exerciseCategory OverheadSquat = Squats
exerciseCategory Deadlift      = Pulls

-- | Parse an exercise name back to its constructor.
-- Returns 'Nothing' for unrecognised names.
parseExercise :: Text -> Maybe Exercise
parseExercise t = case filter (\ex -> exerciseName ex == t) allExercises of
  [ex] -> Just ex
  _    -> Nothing
