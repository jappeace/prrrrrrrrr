{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ImportQualifiedPost #-}
-- | SQLite-backed storage for PR records.
--
-- Uses sqlite-simple for database access.
-- The database is stored at @get_app_files_dir() ++ "/prrrrrrrrr.db"@.
module GymTracker.Storage
  ( withDatabase
  , initDB
  , loadRecords
  , saveRecord
  , loadExerciseHistory
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Database.SQLite.Simple (Connection)
import Database.SQLite.Simple qualified as SQLite
import Foreign.C.String (CString, peekCString)
import GymTracker.Model (Exercise(..), allExercises, exerciseName)

foreign import ccall "get_app_files_dir"
  c_get_app_files_dir :: IO CString

-- | Get the database file path.
getDbPath :: IO FilePath
getDbPath = do
  dir <- c_get_app_files_dir >>= peekCString
  pure (dir ++ "/prrrrrrrrr.db")

-- | Open the database, run an action, then close it.
withDatabase :: (Connection -> IO a) -> IO a
withDatabase action = do
  path <- getDbPath
  SQLite.withConnection path action

-- | Create the pr_records and pr_history tables if they don't exist.
initDB :: Connection -> IO ()
initDB conn = do
  SQLite.execute_ conn
    "CREATE TABLE IF NOT EXISTS pr_records (exercise TEXT PRIMARY KEY, weight_kg REAL NOT NULL)"
  SQLite.execute_ conn
    "CREATE TABLE IF NOT EXISTS pr_history (id INTEGER PRIMARY KEY AUTOINCREMENT, exercise TEXT NOT NULL, weight_kg REAL NOT NULL, recorded_at TEXT NOT NULL DEFAULT (datetime('now')))"

-- | Load all PR records from the database.
loadRecords :: Connection -> IO (Map Exercise Double)
loadRecords conn = do
  rows <- SQLite.query_ conn "SELECT exercise, weight_kg FROM pr_records"
  pure $ Map.fromList
    [ (exercise, weight)
    | (name, weight) <- rows
    , Just exercise  <- [nameToExercise name]
    ]

-- | Save a single PR record (upsert) and append to history.
saveRecord :: Connection -> Exercise -> Double -> IO ()
saveRecord conn exercise weight = do
  let name = exerciseName exercise
  SQLite.execute conn
    "INSERT OR REPLACE INTO pr_records (exercise, weight_kg) VALUES (?, ?)"
    (name, weight)
  SQLite.execute conn
    "INSERT INTO pr_history (exercise, weight_kg) VALUES (?, ?)"
    (name, weight)

-- | Load all history entries for an exercise, newest first.
loadExerciseHistory :: Connection -> Exercise -> IO [(Double, Text)]
loadExerciseHistory conn exercise =
  SQLite.query conn
    "SELECT weight_kg, recorded_at FROM pr_history WHERE exercise = ? ORDER BY id DESC"
    (SQLite.Only (exerciseName exercise))

-- | Parse an exercise name back to its constructor.
nameToExercise :: Text -> Maybe Exercise
nameToExercise t = case filter (\ex -> exerciseName ex == t) allExercises of
  [ex] -> Just ex
  _    -> Nothing
