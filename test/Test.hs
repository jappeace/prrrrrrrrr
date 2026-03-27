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
  , allExercises
  , exerciseName
  , newAppState
  )
import GymTracker.Storage (withDatabase, initDB, loadRecords, saveRecord)
import GymTracker.Views (exerciseListView, enterPRView, appRootView)
import HaskellMobile.Widget (Widget(..))

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
  ]
  where
    nub :: Eq a => [a] -> [a]
    nub [] = []
    nub (x:xs) = x : nub (filter (/= x) xs)

-- | Storage tests use a single withDatabase call each to avoid
-- file locking issues. Each test initializes a fresh table.
storageTests :: TestTree
storageTests = testGroup "Storage"
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
  ]

viewTests :: TestTree
viewTests = testGroup "Views"
  [ testCase "exerciseListView returns Column with correct child count" $ do
      st <- newAppState Map.empty
      widget <- exerciseListView st
      case widget of
        Column children ->
          -- 1 title + 12 exercise buttons
          length children @?= 13
        Text _          -> assertFailure "expected Column, got Text"
        Button _ _      -> assertFailure "expected Column, got Button"
        TextInput _ _ _ -> assertFailure "expected Column, got TextInput"
        Row _           -> assertFailure "expected Column, got Row"

  , testCase "enterPRView returns Column with input and buttons" $ do
      st <- newAppState Map.empty
      widget <- enterPRView st Snatch
      case widget of
        Column children ->
          -- Title + TextInput + Row of buttons = 3
          length children @?= 3
        Text _          -> assertFailure "expected Column, got Text"
        Button _ _      -> assertFailure "expected Column, got Button"
        TextInput _ _ _ -> assertFailure "expected Column, got TextInput"
        Row _           -> assertFailure "expected Column, got Row"

  , testCase "appRootView dispatches to correct screen" $ do
      st <- newAppState Map.empty
      widget <- appRootView st
      case widget of
        Column (Text title : _) ->
          title @?= "PRRRRRRRRR"
        Column _        -> assertFailure "expected title as first child"
        Text _          -> assertFailure "expected Column"
        Button _ _      -> assertFailure "expected Column"
        TextInput _ _ _ -> assertFailure "expected Column"
        Row _           -> assertFailure "expected Column"

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
