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
  , exerciseName
  )
import GymTracker.Storage (withDatabase, saveRecord)
import HaskellMobile.Widget (Widget(..))

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

-- | Exercise list screen: shows all exercises with their current PRs.
exerciseListView :: AppState -> IO Widget
exerciseListView st = do
  records <- readIORef (stRecords st)
  let buttons = map (exerciseButton st records) allExercises
  pure $ Column (Text "PRRRRRRRRR" : buttons)

-- | A single exercise button that navigates to the EnterPR screen.
exerciseButton :: AppState -> Map Exercise Double -> Exercise -> Widget
exerciseButton st records ex =
  Button (exerciseLabel records ex) $ do
    writeIORef (stScreen st) (EnterPR ex)
    writeIORef (stInputText st) ""

-- | Enter PR screen: text input for weight + save/back buttons.
enterPRView :: AppState -> Exercise -> IO Widget
enterPRView st ex = do
  inputVal <- readIORef (stInputText st)
  pure $ Column
    [ Text ("Set PR: " <> exerciseName ex)
    , TextInput "Weight (kg)" inputVal (\t -> writeIORef (stInputText st) t)
    , Row
        [ Button "Save" (savePR st ex)
        , Button "Back" (writeIORef (stScreen st) ExerciseList)
        ]
    ]

-- | Attempt to parse the input and save the PR.
-- Invalid input (empty, non-numeric, non-positive) is silently ignored.
savePR :: AppState -> Exercise -> IO ()
savePR st ex = do
  input <- readIORef (stInputText st)
  case parseWeight input of
    Just w  -> do
      withDatabase $ \db -> saveRecord db ex w
      modifyRecords st (Map.insert ex w)
      writeIORef (stScreen st) ExerciseList
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
