{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ImportQualifiedPost #-}
-- | UI view builders for the gym PR tracker.
module GymTracker.Views
  ( exerciseListView
  , enterPRView
  , appRootView
  )
where

import Data.IORef (readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text, pack, unpack)
import GymTracker.Model
  ( Exercise(..)
  , AppState(..)
  , Screen(..)
  , allExercises
  , allCategories
  , categoryName
  , exerciseCategory
  , exerciseName
  , ExerciseCategory
  )
import GymTracker.Storage (withDatabase, saveRecord, loadExerciseHistory)
import HaskellMobile.Widget (ButtonConfig(..), InputType(..), TextConfig(..), TextInputConfig(..), Widget(..))

-- | Format a weight value for display.
formatWeight :: Double -> Text
formatWeight w =
  let s = show w
  in pack s <> " kg"

-- | Build a button label for an exercise showing its current PR.
exerciseLabel :: Map Exercise Double -> Exercise -> Text
exerciseLabel records ex =
  case Map.lookup ex records of
    Just w  -> exerciseName ex <> ": " <> formatWeight w
    Nothing -> exerciseName ex <> ": No PR"

-- | All exercises belonging to a given category.
exercisesInCategory :: ExerciseCategory -> [Exercise]
exercisesInCategory cat = filter (\ex -> exerciseCategory ex == cat) allExercises

-- | Exercise list screen: shows exercises grouped by category inside a scroll view.
exerciseListView :: AppState -> IO Widget
exerciseListView st = do
  records <- readIORef (stRecords st)
  let categorySection cat =
        Text TextConfig { tcLabel = categoryName cat, tcFontConfig = Nothing }
          : map (exerciseButton st records) (exercisesInCategory cat)
      children = Text TextConfig { tcLabel = "PRRRRRRRRR", tcFontConfig = Nothing }
          : concatMap categorySection allCategories
  pure $ ScrollView [Column children]

-- | A single exercise button that navigates to the EnterPR screen and loads history.
exerciseButton :: AppState -> Map Exercise Double -> Exercise -> Widget
exerciseButton st records ex =
  Button ButtonConfig
    { bcLabel = exerciseLabel records ex
    , bcAction = do
        history <- withDatabase $ \db -> loadExerciseHistory db ex
        writeIORef (stHistory st) history
        writeIORef (stScreen st) (EnterPR ex)
        writeIORef (stInputText st) ""
    , bcFontConfig = Nothing
    }

-- | Enter PR screen: text input for weight + save/back buttons + history log.
enterPRView :: AppState -> Exercise -> IO Widget
enterPRView st ex = do
  inputVal <- readIORef (stInputText st)
  history  <- readIORef (stHistory st)
  let historyWidgets = map historyEntry history
  pure $ Column
    [ Text TextConfig { tcLabel = "Set PR: " <> exerciseName ex, tcFontConfig = Nothing }
    , TextInput TextInputConfig
        { tiInputType = InputText
        , tiHint      = "Weight (kg)"
        , tiValue     = inputVal
        , tiOnChange  = \t -> writeIORef (stInputText st) t
        , tiFontConfig = Nothing
        }
    , Row
        [ Button ButtonConfig
            { bcLabel = "Save", bcAction = savePR st ex, bcFontConfig = Nothing }
        , Button ButtonConfig
            { bcLabel = "Back", bcAction = writeIORef (stScreen st) ExerciseList, bcFontConfig = Nothing }
        ]
    , Column historyWidgets
    ]

-- | Render a single history entry.
historyEntry :: (Double, Text) -> Widget
historyEntry (weight, timestamp) = Text TextConfig
  { tcLabel = timestamp <> ": " <> formatWeight weight, tcFontConfig = Nothing }

-- | Attempt to parse the input and save the PR, then reload history without navigating away.
-- Invalid input (empty, non-numeric, non-positive) is silently ignored.
savePR :: AppState -> Exercise -> IO ()
savePR st ex = do
  input <- readIORef (stInputText st)
  case parseWeight input of
    Just w  -> do
      withDatabase $ \db -> saveRecord db ex w
      modifyRecords st (Map.insert ex w)
      history <- withDatabase $ \db -> loadExerciseHistory db ex
      writeIORef (stHistory st) history
      writeIORef (stInputText st) ""
    Nothing -> pure ()
  where
    modifyRecords :: AppState -> (Map Exercise Double -> Map Exercise Double) -> IO ()
    modifyRecords s f = do
      r <- readIORef (stRecords s)
      writeIORef (stRecords s) (f r)

-- | Parse a weight string to a positive Double.
-- Returns 'Nothing' for empty, non-numeric, zero, or negative input.
parseWeight :: Text -> Maybe Double
parseWeight t =
  case reads (unpack t) of
    [(w, "")] | w > 0 -> Just w
    _                  -> Nothing

-- | Root view: dispatches to the correct screen.
appRootView :: AppState -> IO Widget
appRootView st = do
  screen <- readIORef (stScreen st)
  case screen of
    ExerciseList -> exerciseListView st
    EnterPR ex   -> enterPRView st ex
