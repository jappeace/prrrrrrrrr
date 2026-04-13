{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ImportQualifiedPost #-}
-- | SQLite-backed storage for PR records.
--
-- Uses sqlite-simple for direct SQL access with no Template Haskell.
-- The database is stored at @get_app_files_dir() ++ "/prrrrrrrrr.db"@.
module GymTracker.Storage
  ( withDatabase
  , initDB
  , loadRecords
  , saveRecord
  , loadExerciseHistory
  , getLastSyncTime
  , setLastSyncTime
  , getHistorySince
  , mergeRecord
  , mergeHistoryEntry
  , deleteRecordsByExercise
  , deleteHistoryByExercise
  , deleteSyncMeta
  , queryHistoryByExercise
  , queryHistoryByExerciseAndTime
  , insertHistory
  , Connection
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text, pack, unpack)
import Data.Time (UTCTime, getCurrentTime)
import Database.SQLite.Simple
  ( Connection
  , Only(..)
  , open
  , close
  , execute_
  , execute
  , query
  , query_
  )
import Foreign.C.String (CString, peekCString)
import GymTracker.Model (Exercise(..), exerciseName, parseExercise)

foreign import ccall "get_app_files_dir"
  c_get_app_files_dir :: IO CString

-- | Get the database file path.
getDbPath :: IO FilePath
getDbPath = do
  dir <- c_get_app_files_dir >>= peekCString
  pure (dir ++ "/prrrrrrrrr.db")

-- | Open the database, run an action with the connection, then close it.
withDatabase :: (Connection -> IO a) -> IO a
withDatabase action = do
  path <- getDbPath
  conn <- open path
  result <- action conn
  close conn
  pure result

-- | Create tables if they do not exist.
initDB :: Connection -> IO ()
initDB conn = do
  execute_ conn "CREATE TABLE IF NOT EXISTS pr_record \
    \(exercise TEXT UNIQUE NOT NULL, weight_kg REAL NOT NULL)"
  execute_ conn "CREATE TABLE IF NOT EXISTS pr_history \
    \(id INTEGER PRIMARY KEY, exercise TEXT NOT NULL, weight_kg REAL NOT NULL, \
    \recorded_at TEXT NOT NULL, notes TEXT)"
  execute_ conn "CREATE TABLE IF NOT EXISTS sync_meta \
    \(key TEXT UNIQUE NOT NULL, value TEXT NOT NULL)"

-- | Load all PR records from the database.
loadRecords :: Connection -> IO (Map Exercise Double)
loadRecords conn = do
  rows <- query_ conn "SELECT exercise, weight_kg FROM pr_record"
    :: IO [(Text, Double)]
  pure $ Map.fromList
    [ (exercise, weight)
    | (exerciseText, weight) <- rows
    , Just exercise <- [parseExercise exerciseText]
    ]

-- | Save a single PR record (upsert) and append to history.
saveRecord :: Connection -> Exercise -> Double -> Maybe Text -> IO ()
saveRecord conn exercise weight notes = do
  execute conn
    "INSERT INTO pr_record (exercise, weight_kg) VALUES (?, ?) \
    \ON CONFLICT (exercise) DO UPDATE SET weight_kg = ?"
    (exerciseName exercise, weight, weight)
  now <- getCurrentTime
  execute conn
    "INSERT INTO pr_history (exercise, weight_kg, recorded_at, notes) VALUES (?, ?, ?, ?)"
    (exerciseName exercise, weight, show now, notes)

-- | Load all history entries for an exercise, newest first.
loadExerciseHistory :: Connection -> Exercise -> IO [(Double, Text, Maybe Text)]
loadExerciseHistory conn exercise = do
  rows <- query conn
    "SELECT weight_kg, recorded_at, notes FROM pr_history \
    \WHERE exercise = ? ORDER BY id DESC"
    (Only (exerciseName exercise))
    :: IO [(Double, Text, Maybe Text)]
  pure rows

-- | Read the last sync time from sync_meta, if any.
getLastSyncTime :: Connection -> IO (Maybe UTCTime)
getLastSyncTime conn = do
  rows <- query conn
    "SELECT value FROM sync_meta WHERE key = ?"
    (Only ("last_sync_time" :: Text))
    :: IO [Only Text]
  pure $ case rows of
    [Only val] -> Just (read (unpack val))
    _          -> Nothing

-- | Write the last sync time to sync_meta.
setLastSyncTime :: Connection -> UTCTime -> IO ()
setLastSyncTime conn syncTimestamp =
  execute conn
    "INSERT INTO sync_meta (key, value) VALUES (?, ?) \
    \ON CONFLICT (key) DO UPDATE SET value = ?"
    ("last_sync_time" :: Text, pack (show syncTimestamp), pack (show syncTimestamp))

-- | Get all history entries recorded after the given time.
getHistorySince :: Connection -> UTCTime -> IO [(Exercise, Double, UTCTime, Maybe Text)]
getHistorySince conn since = do
  rows <- query conn
    "SELECT exercise, weight_kg, recorded_at, notes FROM pr_history \
    \WHERE recorded_at > ? ORDER BY id ASC"
    (Only (show since))
    :: IO [(Text, Double, Text, Maybe Text)]
  pure [ (exercise, weight, read (unpack timestamp), notes)
       | (exerciseText, weight, timestamp, notes) <- rows
       , Just exercise <- [parseExercise exerciseText]
       ]

-- | Insert a PR record only if the weight is strictly higher than the existing one.
mergeRecord :: Connection -> Exercise -> Double -> IO ()
mergeRecord conn exercise weight = do
  existing <- query conn
    "SELECT weight_kg FROM pr_record WHERE exercise = ?"
    (Only (exerciseName exercise))
    :: IO [Only Double]
  case existing of
    [Only existingWeight] | existingWeight >= weight -> pure ()
    _ -> execute conn
      "INSERT INTO pr_record (exercise, weight_kg) VALUES (?, ?) \
      \ON CONFLICT (exercise) DO UPDATE SET weight_kg = ?"
      (exerciseName exercise, weight, weight)

-- | Insert a history entry if no duplicate exists (same exercise, weight, and timestamp).
mergeHistoryEntry :: Connection -> Exercise -> Double -> UTCTime -> Maybe Text -> IO ()
mergeHistoryEntry conn exercise weight timestamp notes = do
  existing <- query conn
    "SELECT id FROM pr_history WHERE exercise = ? AND weight_kg = ? AND recorded_at = ?"
    (exerciseName exercise, weight, show timestamp)
    :: IO [Only Int]
  case existing of
    (_:_) -> pure ()
    []    -> execute conn
      "INSERT INTO pr_history (exercise, weight_kg, recorded_at, notes) VALUES (?, ?, ?, ?)"
      (exerciseName exercise, weight, show timestamp, notes)

-- | Delete all PR records for a given exercise (used by tests).
deleteRecordsByExercise :: Connection -> Exercise -> IO ()
deleteRecordsByExercise conn exercise =
  execute conn "DELETE FROM pr_record WHERE exercise = ?"
    (Only (exerciseName exercise))

-- | Delete all history entries for a given exercise (used by tests).
deleteHistoryByExercise :: Connection -> Exercise -> IO ()
deleteHistoryByExercise conn exercise =
  execute conn "DELETE FROM pr_history WHERE exercise = ?"
    (Only (exerciseName exercise))

-- | Delete a sync_meta entry by key (used by tests).
deleteSyncMeta :: Connection -> Text -> IO ()
deleteSyncMeta conn metaKey =
  execute conn "DELETE FROM sync_meta WHERE key = ?"
    (Only metaKey)

-- | Query history rows matching exercise and exact timestamp (used by tests).
queryHistoryByExercise :: Connection -> Exercise -> IO [Only Int]
queryHistoryByExercise conn exercise =
  query conn
    "SELECT id FROM pr_history WHERE exercise = ?"
    (Only (exerciseName exercise))

-- | Query history rows matching exercise, weight, and exact timestamp (used by tests).
queryHistoryByExerciseAndTime :: Connection -> Exercise -> Double -> UTCTime -> IO [Only Int]
queryHistoryByExerciseAndTime conn exercise weight timestamp =
  query conn
    "SELECT id FROM pr_history WHERE exercise = ? AND weight_kg = ? AND recorded_at = ?"
    (exerciseName exercise, weight, show timestamp)

-- | Insert a raw history entry (used by tests that need specific timestamps).
insertHistory :: Connection -> Exercise -> Double -> UTCTime -> Maybe Text -> IO ()
insertHistory conn exercise weight timestamp notes =
  execute conn
    "INSERT INTO pr_history (exercise, weight_kg, recorded_at, notes) VALUES (?, ?, ?, ?)"
    (exerciseName exercise, weight, show timestamp, notes)
