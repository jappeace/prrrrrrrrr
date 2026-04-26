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
  , confettiOverlay
  , estimate1RM
  , parseReps
  )
where

import Data.IORef (readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text, pack, unpack)
import System.Random (StdGen, randomRs)
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
import Hatter (Action, OnChange, ActionM, createAction, createOnChange)
import Hatter.DeviceInfo (DeviceInfo(..), getDeviceInfo)
import Hatter.Widget
  ( ButtonConfig(..)
  , Color(..)
  , InputType(..)
  , TextAlignment(..)
  , TextConfig(..)
  , TextInputConfig(..)
  , Widget(..)
  , WidgetStyle(..)
  , andThen
  , column
  , easeOutAnimation
  , linearAnimation
  , row
  , scrollColumn
  , stack
  , defaultStyle
  )

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
  , aaNotesInput      :: OnChange
    -- ^ Text input change handler for optional notes.
  , aaRepsInput       :: OnChange
    -- ^ Text input change handler for reps entry.
  }

-- | Create all 'Action' / 'OnChange' handles for the app.
-- Must be called inside 'runActionM'.
createAppActions :: AppState -> ActionM AppActions
createAppActions st = do
  exerciseButtons <- fmap Map.fromList $ mapM mkExerciseAction allExercises
  saveButtons     <- fmap Map.fromList $ mapM mkSaveAction allExercises
  back            <- createAction $ do
    writeIORef (stConfetti st) False
    writeIORef (stRepsInput st) ""
    writeIORef (stScreen st) ExerciseList
  weightInput     <- createOnChange (\t -> writeIORef (stInputText st) t)
  percentageInput <- createOnChange (\t ->
    writeIORef (stPercentage st) (parsePercentage t))
  notesInput      <- createOnChange (\t -> writeIORef (stNotesInput st) t)
  repsInput       <- createOnChange (\t -> writeIORef (stRepsInput st) t)
  pure AppActions
    { aaExerciseButtons = exerciseButtons
    , aaSaveButtons     = saveButtons
    , aaBackButton      = back
    , aaWeightInput     = weightInput
    , aaPercentageInput = percentageInput
    , aaNotesInput      = notesInput
    , aaRepsInput       = repsInput
    }
  where
    mkExerciseAction :: Exercise -> ActionM (Exercise, Action)
    mkExerciseAction ex = do
      action <- createAction $ do
        history <- withDatabase $ \conn -> loadExerciseHistory conn ex
        writeIORef (stHistory st) history
        writeIORef (stConfetti st) False
        writeIORef (stScreen st) (EnterPR ex)
        writeIORef (stInputText st) ""
        writeIORef (stNotesInput st) ""
        writeIORef (stRepsInput st) ""
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
        { tiInputType  = InputNumber
        , tiHint       = "% of 1RM"
        , tiValue      = if percentage == 0 then "" else pack (show percentage)
        , tiOnChange   = aaPercentageInput actions
        , tiFontConfig = Nothing
        , tiAutoFocus  = False
        }
      categorySection cat =
        Styled centeredText (Text TextConfig { tcLabel = categoryName cat, tcFontConfig = Nothing })
          : concatMap (exerciseWithPercentage actions records percentage) (exercisesInCategory cat)
      children = Styled centeredText (Text TextConfig { tcLabel = "PRRRRRRRRR", tcFontConfig = Nothing })
          : percentageRow
          : concatMap categorySection allCategories
  pure $ scrollColumn children

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
-- Shows a confetti animation overlay after a successful save.
enterPRView :: AppActions -> AppState -> Exercise -> IO Widget
enterPRView actions st ex = do
  inputVal    <- readIORef (stInputText st)
  notesVal    <- readIORef (stNotesInput st)
  repsVal     <- readIORef (stRepsInput st)
  history     <- readIORef (stHistory st)
  showConfetti <- readIORef (stConfetti st)
  let historyWidgets = map historyEntry history
      estimateLabel = case (parseWeight inputVal, parseReps repsVal) of
        (Just weight, Just reps) | reps > 1 ->
          let estimated = estimate1RM weight reps
              rounded = fromIntegral (round (estimated * 10) :: Int) / 10.0 :: Double
          in  "Est. 1RM: " <> formatWeight rounded
        _                                    -> ""
      formWidgets =
        [ Styled centeredText $ Text TextConfig { tcLabel = "Set PR: ", tcFontConfig = Nothing }
        , Styled centeredText $ Text TextConfig { tcLabel = exerciseName ex, tcFontConfig = Nothing }
        , Styled centeredText $ TextInput TextInputConfig
            { tiInputType  = InputNumber
            , tiHint       = "Weight (kg)"
            , tiValue      = inputVal
            , tiOnChange   = aaWeightInput actions
            , tiFontConfig = Nothing
            , tiAutoFocus  = True
            }
        , Styled centeredText $ TextInput TextInputConfig
            { tiInputType  = InputNumber
            , tiHint       = "Reps (default 1)"
            , tiValue      = repsVal
            , tiOnChange   = aaRepsInput actions
            , tiFontConfig = Nothing
            , tiAutoFocus  = False
            }
        , Styled centeredText $ Text TextConfig { tcLabel = estimateLabel, tcFontConfig = Nothing }
        , Styled centeredText $ TextInput TextInputConfig
            { tiInputType  = InputText
            , tiHint       = "Notes (optional)"
            , tiValue      = notesVal
            , tiOnChange   = aaNotesInput actions
            , tiFontConfig = Nothing
            , tiAutoFocus  = False
            }
        , row
            [ Button ButtonConfig
                { bcLabel = "Save"
                , bcAction = Map.findWithDefault (aaBackButton actions) ex (aaSaveButtons actions)
                , bcFontConfig = Nothing
                }
            , Button ButtonConfig
                { bcLabel = "Back", bcAction = aaBackButton actions, bcFontConfig = Nothing }
            ]
        , column historyWidgets
        ]
  confettiLayer <- if showConfetti
    then fmap (: []) (confettiOverlay (stConfettiSeed st))
    else pure []
  -- Always use stack as root so the diff algorithm sees a stable root
  -- type across renders.  Confetti floats as a second stack child on top
  -- of the form column, using wsTouchPassthrough so taps pass through.
  pure $ stack $ column formWidgets : confettiLayer

-- | Render a single history entry, optionally showing reps and notes.
historyEntry :: (Double, Int, Text, Maybe Text) -> Widget
historyEntry (weight, reps, timestamp, notes) =
  let weightText = if reps > 1
        then formatWeight weight <> " x " <> pack (show reps)
        else formatWeight weight
      base = timestamp <> ": " <> weightText
      label = case notes of
        Just n  -> base <> " (" <> n <> ")"
        Nothing -> base
  in Styled centeredText $ Text TextConfig { tcLabel = label, tcFontConfig = Nothing }

-- | Confetti animation overlay — particles explode outward from the origin.
-- Shown on the EnterPR screen after saving a new personal record.
-- Uses random positions and colors so each celebration looks unique.
-- Each particle scatters from the origin (top-left) to a random screen
-- position over 1.5s (ease-out), then fades out over 0.8s (linear).
--
-- Takes a deterministic 'StdGen' so the widget tree is identical across
-- re-renders.  Without this, hatter's diff engine would see different
-- particles on each render, re-register tweens, and restart the animation.
confettiOverlay :: StdGen -> IO Widget
confettiOverlay gen = do
  deviceInfo <- getDeviceInfo
  let -- Convert physical pixels to dp; desktop returns 0 so use fallback
      density = max 1.0 (diScreenDensity deviceInfo)
      rawWidth = diScreenWidth deviceInfo
      rawHeight = diScreenHeight deviceInfo
      dpWidth :: Double
      dpWidth  = if rawWidth  == 0 then 400 else fromIntegral rawWidth  / density
      dpHeight :: Double
      dpHeight = if rawHeight == 0 then 800 else fromIntegral rawHeight / density
      randoms = randomRs (0 :: Int, 999) gen
      -- Take 3 random ints per particle: x-offset seed, y-offset seed, color index
      triples = takeTriples particleCount randoms
      particles = map (mkParticle dpWidth dpHeight) triples
  pure $ Styled (defaultStyle { wsTouchPassthrough = Just True })
       $ stack particles
  where
    particleCount :: Int
    particleCount = 20

    -- | Extract groups of three from a list.
    takeTriples :: Int -> [Int] -> [(Int, Int, Int)]
    takeTriples 0 _             = []
    takeTriples _ []            = []
    takeTriples _ [_]           = []
    takeTriples _ [_, _]        = []
    takeTriples n (a:b:c:rest)  = (a, b, c) : takeTriples (n - 1) rest

    -- | Build a single confetti particle with scatter + fade animation.
    mkParticle :: Double -> Double -> (Int, Int, Int) -> Widget
    mkParticle screenWidth screenHeight (xSeed, ySeed, colorSeed) =
      let targetX = fromIntegral (xSeed `mod` 1000) / 999.0 * screenWidth
          targetY = fromIntegral (ySeed `mod` 1000) / 999.0 * screenHeight
          color   = palette !! (colorSeed `mod` length palette)
          originStyle = defaultStyle
            { wsTranslateX = Just 0
            , wsTranslateY = Just 0
            , wsTextColor  = Just color
            }
          targetStyle = defaultStyle
            { wsTranslateX = Just targetX
            , wsTranslateY = Just targetY
            , wsTextColor  = Just color
            }
          fadeStyle = defaultStyle
            { wsTranslateX = Just targetX
            , wsTranslateY = Just targetY
            , wsTextColor  = Just (color { colorAlpha = 0 })
            }
          animConfig = easeOutAnimation 1.5 originStyle targetStyle
                         `andThen`
                       linearAnimation 0.8 targetStyle fadeStyle
      in Animated animConfig
           $ Styled fadeStyle
               (Text TextConfig { tcLabel = "*", tcFontConfig = Nothing })

    palette :: [Color]
    palette =
      [ Color 255 215 0   255  -- gold
      , Color 255 68  68  255  -- red
      , Color 68  255 68  255  -- green
      , Color 68  68  255 255  -- blue
      , Color 255 68  255 255  -- magenta
      , Color 68  255 255 255  -- cyan
      ]

-- | Attempt to parse the input and save the PR, then reload history without navigating away.
-- Invalid input (empty, non-numeric, non-positive) is silently ignored.
savePR :: AppState -> Exercise -> IO ()
savePR st ex = do
  input <- readIORef (stInputText st)
  notesRaw <- readIORef (stNotesInput st)
  repsRaw <- readIORef (stRepsInput st)
  let notes = if notesRaw == "" then Nothing else Just notesRaw
      reps = case parseReps repsRaw of
        Just r  -> r
        Nothing -> 1
  case parseWeight input of
    Just w  -> do
      withDatabase $ \conn -> saveRecord conn ex w reps notes
      modifyRecords st (Map.insert ex w)
      history <- withDatabase $ \conn -> loadExerciseHistory conn ex
      writeIORef (stHistory st) history
      writeIORef (stInputText st) ""
      writeIORef (stNotesInput st) ""
      writeIORef (stRepsInput st) ""
      writeIORef (stConfetti st) True
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

-- | Estimate 1RM from an N-rep max using the Epley formula.
estimate1RM :: Double -> Int -> Double
estimate1RM weight 1 = weight
estimate1RM weight reps = weight * (1 + fromIntegral reps / 30)

-- | Parse a reps string to a positive Int.
-- Empty string returns Just 1 (default). Non-positive or non-numeric returns Nothing.
parseReps :: Text -> Maybe Int
parseReps t
  | t == ""   = Just 1
  | otherwise = case reads (unpack t) of
      [(n, "")] | n > 0 -> Just n
      _                  -> Nothing

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
