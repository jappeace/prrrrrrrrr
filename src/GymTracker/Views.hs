{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ImportQualifiedPost #-}
-- | UI view builders for the gym PR tracker.
module GymTracker.Views
  ( AppActions(..)
  , createAppActions
  , exerciseListView
  , enterPRView
  , appRootView
  , calculatePercentage
  )
where

import Data.IORef (readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text, pack, unpack)
import GymTracker.AppState (AppState(..), Screen(..))
import GymTracker.Model
  ( Exercise(..)
  , allExercises
  , allCategories
  , categoryName
  , exerciseCategory
  , exerciseName
  , ExerciseCategory
  )
import GymTracker.Storage (withDatabase, saveRecord, loadExerciseHistory)
import GymTracker.Sync (triggerSync)
import HaskellMobile (Action, OnChange, ActionM, createAction, createOnChange)
import HaskellMobile.Widget (ButtonConfig(..), InputType(..), TextAlignment(..), TextConfig(..), TextInputConfig(..), Widget(..), WidgetStyle(..), defaultStyle)

-- | Pre-created callback handles for all UI interactions.
-- Created once at init time via 'createAppActions'.
data AppActions = AppActions
  { aaExerciseButtons :: Map Exercise Action
    -- ^ Navigate to the EnterPR screen for each exercise.
  , aaSaveButtons     :: Map Exercise Action
    -- ^ Save the current PR for each exercise.
  , aaBackButton      :: Action
    -- ^ Navigate back to the exercise list.
  , aaWeightInput     :: OnChange
    -- ^ Text input change handler for weight entry.
  , aaPercentageInput :: OnChange
    -- ^ Text input change handler for percentage entry on exercise list.
  }

-- | Create all 'Action' / 'OnChange' handles for the app.
-- Must be called inside 'runActionM'.
createAppActions :: AppState -> ActionM AppActions
createAppActions st = do
  exerciseButtons <- fmap Map.fromList $ mapM mkExerciseAction allExercises
  saveButtons     <- fmap Map.fromList $ mapM mkSaveAction allExercises
  back            <- createAction (writeIORef (stScreen st) ExerciseList)
  weightInput     <- createOnChange (\t -> writeIORef (stInputText st) t)
  percentageInput <- createOnChange (\t ->
    writeIORef (stPercentage st) (parsePercentage t))
  pure AppActions
    { aaExerciseButtons = exerciseButtons
    , aaSaveButtons     = saveButtons
    , aaBackButton      = back
    , aaWeightInput     = weightInput
    , aaPercentageInput = percentageInput
    }
  where
    mkExerciseAction :: Exercise -> ActionM (Exercise, Action)
    mkExerciseAction ex = do
      action <- createAction $ do
        history <- withDatabase $ loadExerciseHistory ex
        writeIORef (stHistory st) history
        writeIORef (stScreen st) (EnterPR ex)
        writeIORef (stInputText st) ""
      pure (ex, action)
    mkSaveAction :: Exercise -> ActionM (Exercise, Action)
    mkSaveAction ex = do
      action <- createAction (savePR st ex)
      pure (ex, action)

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
exerciseListView :: AppActions -> AppState -> IO Widget
exerciseListView actions st = do
  records    <- readIORef (stRecords st)
  percentage <- readIORef (stPercentage st)
  let percentageRow = Styled centeredText $ TextInput TextInputConfig
        { tiInputType = InputNumber
        , tiHint      = "% of 1RM"
        , tiValue     = if percentage == 0 then "" else pack (show percentage)
        , tiOnChange  = aaPercentageInput actions
        , tiFontConfig = Nothing
        }
      categorySection cat =
        Styled centeredText (Text TextConfig { tcLabel = categoryName cat, tcFontConfig = Nothing })
          : concatMap (exerciseWithPercentage actions records percentage) (exercisesInCategory cat)
      children = Styled centeredText (Text TextConfig { tcLabel = "PRRRRRRRRR", tcFontConfig = Nothing })
          : percentageRow
          : concatMap categorySection allCategories
  pure $ ScrollView [Column children]

-- | A single exercise button, optionally followed by a calculated percentage text.
-- Returns one widget (button only) when percentage is 0 or the exercise has no PR,
-- or two widgets (button + calculated weight) when both are present.
exerciseWithPercentage :: AppActions -> Map Exercise Double -> Word -> Exercise -> [Widget]
exerciseWithPercentage actions records percentage ex =
  let button = Button ButtonConfig
        { bcLabel = exerciseLabel records ex
        , bcAction = Map.findWithDefault (aaBackButton actions) ex (aaExerciseButtons actions)
        , bcFontConfig = Nothing
        }
  in case Map.lookup ex records of
    Just prWeight | percentage > 0 ->
      let calculated = calculatePercentage prWeight percentage
      in [ button
         , Styled centeredText $ Text TextConfig
             { tcLabel = formatWeight calculated <> " @ " <> pack (show percentage) <> "%"
             , tcFontConfig = Nothing
             }
         ]
    Just _  -> [button]
    Nothing -> [button]

-- | Enter PR screen: text input for weight + save/back buttons + history log.
enterPRView :: AppActions -> AppState -> Exercise -> IO Widget
enterPRView actions st ex = do
  inputVal <- readIORef (stInputText st)
  history  <- readIORef (stHistory st)
  let historyWidgets = map historyEntry history
  pure $ Column
    [ Styled centeredText $ Text TextConfig { tcLabel = "Set PR: ", tcFontConfig = Nothing }
    , Styled centeredText $ Text TextConfig { tcLabel = exerciseName ex, tcFontConfig = Nothing }
    , Styled centeredText $ TextInput TextInputConfig
        { tiInputType = InputNumber
        , tiHint      = "Weight (kg)"
        , tiValue     = inputVal
        , tiOnChange  = aaWeightInput actions
        , tiFontConfig = Nothing
        }
    , Row
        [ Button ButtonConfig
            { bcLabel = "Save"
            , bcAction = Map.findWithDefault (aaBackButton actions) ex (aaSaveButtons actions)
            , bcFontConfig = Nothing
            }
        , Button ButtonConfig
            { bcLabel = "Back", bcAction = aaBackButton actions, bcFontConfig = Nothing }
        ]
    , Column historyWidgets
    ]

-- | Render a single history entry.
historyEntry :: (Double, Text) -> Widget
historyEntry (weight, timestamp) = Styled centeredText $ Text TextConfig
  { tcLabel = timestamp <> ": " <> formatWeight weight, tcFontConfig = Nothing }

-- | Attempt to parse the input and save the PR, then reload history without navigating away.
-- Invalid input (empty, non-numeric, non-positive) is silently ignored.
savePR :: AppState -> Exercise -> IO ()
savePR st ex = do
  input <- readIORef (stInputText st)
  case parseWeight input of
    Just w  -> do
      withDatabase $ saveRecord ex w
      modifyRecords st (Map.insert ex w)
      history <- withDatabase $ loadExerciseHistory ex
      writeIORef (stHistory st) history
      writeIORef (stInputText st) ""
      triggerSync st
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

-- | Calculate a percentage of a 1RM weight.
calculatePercentage :: Double -> Word -> Double
calculatePercentage prWeight percentage =
  prWeight * fromIntegral percentage / 100.0

-- | Parse a percentage string to a 'Word', defaulting to 0 on invalid input.
parsePercentage :: Text -> Word
parsePercentage t =
  case reads (unpack t) of
    [(n, "")] | n > 0, n <= 100 -> n
    _                            -> 0

-- | Center-aligned text for category headers.
centeredText :: WidgetStyle
centeredText = defaultStyle { wsTextAlign = Just AlignCenter }

-- | Padding for round watch screens — keeps content away from curved edges.
roundScreenPadding :: WidgetStyle
roundScreenPadding = defaultStyle { wsPadding = Just 24 }

-- | Root view: dispatches to the correct screen, padded for round displays.
appRootView :: AppActions -> AppState -> IO Widget
appRootView actions st = do
  screen <- readIORef (stScreen st)
  inner <- case screen of
    ExerciseList -> exerciseListView actions st
    EnterPR ex   -> enterPRView actions st ex
  pure $ Styled roundScreenPadding inner
