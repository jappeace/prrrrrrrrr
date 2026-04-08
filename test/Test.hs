{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ImportQualifiedPost #-}
module Main where

import Test.Tasty
import Test.Tasty.HUnit

import Data.Map.Strict qualified as Map
import Data.IORef (readIORef, writeIORef)
import Data.Text (Text, unpack)
import GymTracker.Model
  ( Exercise(..)
  , Screen(..)
  , AppState(..)
  , ExerciseCategory(..)
  , allExercises
  , allCategories
  , categoryName
  , exerciseCategory
  , exerciseName
  , newAppState
  )
import GymTracker.Storage (withDatabase, initDB, loadRecords, saveRecord, loadExerciseHistory)
import GymTracker.Views (exerciseListView, enterPRView, appRootView)
import HaskellMobile.Widget (TextConfig(..), Widget(..))

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "prrrrrrrrr" [modelTests, storageTests, viewTests, parseTests]

modelTests :: TestTree
modelTests = testGroup "Model"
  [ testCase "allExercises has 12 entries" $
      length allExercises @?= 12

  , testCase "exerciseName is unique for each exercise" $
      let names = map exerciseName allExercises
      in length names @?= length (nub names)

  , testCase "allExercises covers Enum range" $
      allExercises @?= [Snatch .. SquatJerk]

  , testCase "all exercises are assigned to exactly one category" $
      let exercisesPerCategory = map (\cat -> length (filter (\ex -> exerciseCategory ex == cat) allExercises)) allCategories
      in sum exercisesPerCategory @?= length allExercises

  , testCase "Snatch and PowerSnatch are in Snatches" $ do
      exerciseCategory Snatch      @?= Snatches
      exerciseCategory PowerSnatch @?= Snatches

  , testCase "Clean, PowerClean, CleanAndJerk are in Cleans" $ do
      exerciseCategory Clean       @?= Cleans
      exerciseCategory PowerClean  @?= Cleans
      exerciseCategory CleanAndJerk @?= Cleans

  , testCase "PushPress, PushJerk, SquatJerk are in JerksAndPresses" $ do
      exerciseCategory PushPress @?= JerksAndPresses
      exerciseCategory PushJerk  @?= JerksAndPresses
      exerciseCategory SquatJerk @?= JerksAndPresses

  , testCase "FrontSquat, BackSquat, OverheadSquat are in Squats" $ do
      exerciseCategory FrontSquat    @?= Squats
      exerciseCategory BackSquat     @?= Squats
      exerciseCategory OverheadSquat @?= Squats

  , testCase "Deadlift is in Pulls" $
      exerciseCategory Deadlift @?= Pulls
  ]
  where
    nub :: Eq a => [a] -> [a]
    nub [] = []
    nub (x:xs) = x : nub (filter (/= x) xs)

-- | Storage tests run sequentially — SQLite is compiled with
-- SQLITE_THREADSAFE=0, so concurrent access to the same file fails.
storageTests :: TestTree
storageTests = sequentialTestGroup "Storage" AllFinish
  [ testCase "saveRecord then loadRecords roundtrip" $ do
      withDatabase $ \db -> do
        initDB db
        saveRecord db Snatch 80.0
        saveRecord db Deadlift 150.5
        records <- loadRecords db
        Map.lookup Snatch records @?= Just 80.0
        Map.lookup Deadlift records @?= Just 150.5

  , testCase "saveRecord overwrites previous value" $ do
      withDatabase $ \db -> do
        initDB db
        saveRecord db BackSquat 100.0
        saveRecord db BackSquat 110.0
        records <- loadRecords db
        Map.lookup BackSquat records @?= Just 110.0

  , testCase "loadExerciseHistory returns entry after saveRecord" $ do
      withDatabase $ \db -> do
        initDB db
        saveRecord db FrontSquat 90.0
        history <- loadExerciseHistory db FrontSquat
        case history of
          [] -> assertFailure "expected at least one history entry"
          ((weight, _timestamp) : _) -> weight @?= 90.0

  , testCase "multiple saveRecord calls accumulate in history newest first" $ do
      withDatabase $ \db -> do
        initDB db
        saveRecord db PushPress 60.0
        saveRecord db PushPress 65.0
        saveRecord db PushPress 70.0
        history <- loadExerciseHistory db PushPress
        let weights = map fst history
        -- newest first: 70, 65, 60 (plus any from prior test runs)
        take 3 weights @?= [70.0, 65.0, 60.0]
  ]

viewTests :: TestTree
viewTests = testGroup "Views"
  [ testCase "exerciseListView returns ScrollView wrapping Column with correct child count" $ do
      st <- newAppState Map.empty
      widget <- exerciseListView st
      case widget of
        ScrollView [Column children] ->
          -- 1 title + 5 category headers + 12 exercise buttons = 18
          length children @?= 18
        ScrollView _ -> assertFailure "expected ScrollView with single Column child"
        _            -> assertFailure "expected ScrollView"

  , testCase "exerciseListView second Column child is Text Snatches category header" $ do
      st <- newAppState Map.empty
      widget <- exerciseListView st
      case widget of
        ScrollView [Column (_ : secondChild : _)] ->
          case secondChild of
            Text config -> tcLabel config @?= categoryName Snatches
            _           -> assertFailure "expected Text for category header"
        ScrollView _ -> assertFailure "expected at least 2 children in Column"
        _            -> assertFailure "expected ScrollView"

  , testCase "enterPRView returns Column with input, buttons, and history section" $ do
      st <- newAppState Map.empty
      widget <- enterPRView st Snatch
      case widget of
        Column children ->
          -- Title + TextInput + Row of buttons + Column history = 4
          length children @?= 4
        Text _          -> assertFailure "expected Column, got Text"
        Button _        -> assertFailure "expected Column, got Button"
        TextInput _     -> assertFailure "expected Column, got TextInput"
        Row _           -> assertFailure "expected Column, got Row"
        ScrollView _    -> assertFailure "expected Column, got ScrollView"
        Image _         -> assertFailure "expected Column, got Image"
        Styled _ _      -> assertFailure "expected Column, got Styled"

  , testCase "enterPRView with history shows entries in 4th Column child" $ do
      st <- newAppState Map.empty
      writeIORef (stHistory st) [(100.0, "2026-01-01 12:00:00"), (90.0, "2025-12-01 10:00:00")]
      widget <- enterPRView st Snatch
      case widget of
        Column [_, _, _, Column historyWidgets] ->
          length historyWidgets @?= 2
        Column _ -> assertFailure "expected 4 children with history Column as 4th"
        _        -> assertFailure "expected Column"

  , testCase "appRootView dispatches to correct screen" $ do
      st <- newAppState Map.empty
      widget <- appRootView st
      case widget of
        Styled _ (ScrollView [Column (Text config : _)]) ->
          tcLabel config @?= "PRRRRRRRRR"
        Styled _ (ScrollView _) -> assertFailure "expected ScrollView with Column as first child"
        Styled _ _              -> assertFailure "expected Styled wrapping ScrollView"
        _                       -> assertFailure "expected Styled"

  , testCase "screen navigation: list -> enter PR -> back" $ do
      st <- newAppState Map.empty
      screen0 <- readIORef (stScreen st)
      screen0 @?= ExerciseList
      writeIORef (stScreen st) (EnterPR Snatch)
      screen1 <- readIORef (stScreen st)
      screen1 @?= EnterPR Snatch
      writeIORef (stScreen st) ExerciseList
      screen2 <- readIORef (stScreen st)
      screen2 @?= ExerciseList
  ]

-- | Replicate the parseWeight logic from Views for testing.
parseWeightText :: Text -> Maybe Double
parseWeightText t =
  case reads (unpack t) of
    [(w, "")] | w > 0 -> Just w
    _                  -> Nothing

parseTests :: TestTree
parseTests = testGroup "Weight parsing"
  [ testCase "valid positive number parses" $
      parseWeightText "80.5" @?= Just 80.5

  , testCase "integer parses as Double" $
      parseWeightText "100" @?= Just 100.0

  , testCase "empty string does not parse" $
      parseWeightText "" @?= Nothing

  , testCase "non-numeric does not parse" $
      parseWeightText "abc" @?= Nothing

  , testCase "negative number does not parse" $
      parseWeightText "-5" @?= Nothing

  , testCase "zero does not parse" $
      parseWeightText "0" @?= Nothing
  ]
