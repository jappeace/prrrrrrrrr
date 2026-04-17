{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | SQLite-backed storage for PR records.
--
-- Uses beam-sqlite for type-safe queries on top of sqlite-simple.
-- The database is stored at @getAppFilesDir ++ "/prrrrrrrrr.db"@.
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

import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text, pack, unpack)
import Data.Time (UTCTime, getCurrentTime)
import Database.Beam
  ( Beamable
  , Columnar
  , Database
  , DatabaseSettings
  , Table(..)
  , TableEntity
  , all_
  , default_
  , defaultDbSettings
  , delete
  , fieldNamed
  , guard_
  , insert
  , insertExpressions
  , modifyTableFields
  , orderBy_
  , asc_
  , desc_
  , primaryKey
  , runDelete
  , runInsert
  , runSelectReturningList
  , runSelectReturningOne
  , select
  , setEntityName
  , tableModification
  , val_
  , withDbModification
  , (==.)
  , (>.)
  , (<-.)
  )
import Database.Beam.Backend.SQL.BeamExtensions
  ( insertOnConflict
  , conflictingFields
  , onConflictUpdateSet
  , SqlSerial(..)
  )
import Database.Beam.Sqlite (Sqlite, runBeamSqlite)
import Database.SQLite.Simple (Connection)
import Database.SQLite.Simple qualified as SQLite
import GHC.Generics (Generic)
import GymTracker.Model (Exercise(..), exerciseName, parseExercise)
import Hatter.FilesDir (getAppFilesDir)

-- | pr_record table: stores current PR for each exercise.
data PrRecordT f = PrRecord
  { prExercise :: Columnar f Text
  , prWeightKg :: Columnar f Double
  } deriving (Generic)

instance Beamable PrRecordT

instance Table PrRecordT where
  data PrimaryKey PrRecordT f = PrRecordKey (Columnar f Text)
    deriving (Generic)
  primaryKey = PrRecordKey . prExercise

instance Beamable (PrimaryKey PrRecordT)

-- | pr_history table: append-only log of every PR entry.
data PrHistoryT f = PrHistory
  { phId         :: Columnar f (SqlSerial Int64)
  , phExercise   :: Columnar f Text
  , phWeightKg   :: Columnar f Double
  , phRecordedAt :: Columnar f Text
  , phNotes      :: Columnar f (Maybe Text)
  } deriving (Generic)

instance Beamable PrHistoryT

instance Table PrHistoryT where
  data PrimaryKey PrHistoryT f = PrHistoryKey (Columnar f (SqlSerial Int64))
    deriving (Generic)
  primaryKey = PrHistoryKey . phId

instance Beamable (PrimaryKey PrHistoryT)

-- | sync_meta table: key-value store for sync metadata.
data SyncMetaT f = SyncMeta
  { smKey   :: Columnar f Text
  , smValue :: Columnar f Text
  } deriving (Generic)

instance Beamable SyncMetaT

instance Table SyncMetaT where
  data PrimaryKey SyncMetaT f = SyncMetaKey (Columnar f Text)
    deriving (Generic)
  primaryKey = SyncMetaKey . smKey

instance Beamable (PrimaryKey SyncMetaT)

-- | The full database schema.
data PrDb f = PrDb
  { dbPrRecord  :: f (TableEntity PrRecordT)
  , dbPrHistory :: f (TableEntity PrHistoryT)
  , dbSyncMeta  :: f (TableEntity SyncMetaT)
  } deriving (Generic)

instance Database Sqlite PrDb

-- | Database settings with column names matching the existing schema.
prDb :: DatabaseSettings Sqlite PrDb
prDb = defaultDbSettings `withDbModification` PrDb
  { dbPrRecord = setEntityName "pr_record" <>
      modifyTableFields tableModification
        { prExercise = fieldNamed "exercise"
        , prWeightKg = fieldNamed "weight_kg"
        }
  , dbPrHistory = setEntityName "pr_history" <>
      modifyTableFields tableModification
        { phId         = fieldNamed "id"
        , phExercise   = fieldNamed "exercise"
        , phWeightKg   = fieldNamed "weight_kg"
        , phRecordedAt = fieldNamed "recorded_at"
        , phNotes      = fieldNamed "notes"
        }
  , dbSyncMeta = setEntityName "sync_meta" <>
      modifyTableFields tableModification
        { smKey   = fieldNamed "key"
        , smValue = fieldNamed "value"
        }
  }

-- | Get the database file path.
getDbPath :: IO FilePath
getDbPath = do
  dir <- getAppFilesDir
  pure (dir ++ "/prrrrrrrrr.db")

-- | Open the database, run an action with the connection, then close it.
withDatabase :: (Connection -> IO a) -> IO a
withDatabase action = do
  path <- getDbPath
  conn <- SQLite.open path
  result <- action conn
  SQLite.close conn
  pure result

-- | Create tables if they do not exist.
-- Kept as raw SQL — beam-migrate would be overkill for 3 static tables.
initDB :: Connection -> IO ()
initDB conn = do
  SQLite.execute_ conn "CREATE TABLE IF NOT EXISTS pr_record \
    \(exercise TEXT UNIQUE NOT NULL, weight_kg REAL NOT NULL)"
  SQLite.execute_ conn "CREATE TABLE IF NOT EXISTS pr_history \
    \(id INTEGER PRIMARY KEY, exercise TEXT NOT NULL, weight_kg REAL NOT NULL, \
    \recorded_at TEXT NOT NULL, notes TEXT)"
  SQLite.execute_ conn "CREATE TABLE IF NOT EXISTS sync_meta \
    \(key TEXT UNIQUE NOT NULL, value TEXT NOT NULL)"

-- | Load all PR records from the database.
loadRecords :: Connection -> IO (Map Exercise Double)
loadRecords conn = do
  rows <- runBeamSqlite conn $
    runSelectReturningList $ select $ all_ (dbPrRecord prDb)
  pure $ Map.fromList
    [ (exercise, prWeightKg row)
    | row <- rows
    , Just exercise <- [parseExercise (prExercise row)]
    ]

-- | Save a single PR record (upsert) and append to history.
saveRecord :: Connection -> Exercise -> Double -> Maybe Text -> IO ()
saveRecord conn exercise weight notes = do
  let name = exerciseName exercise
  runBeamSqlite conn $ do
    runInsert $ insertOnConflict (dbPrRecord prDb)
      (insertExpressions [PrRecord (val_ name) (val_ weight)])
      (conflictingFields prExercise)
      (onConflictUpdateSet (\fields _excluded ->
        prWeightKg fields <-. val_ weight))
  now <- getCurrentTime
  runBeamSqlite conn $
    runInsert $ insert (dbPrHistory prDb) $
      insertExpressions
        [ PrHistory default_ (val_ name) (val_ weight)
                    (val_ (pack (show now))) (val_ notes) ]

-- | Load all history entries for an exercise, newest first.
loadExerciseHistory :: Connection -> Exercise -> IO [(Double, Text, Maybe Text)]
loadExerciseHistory conn exercise = do
  rows <- runBeamSqlite conn $
    runSelectReturningList $ select $
      orderBy_ (\row -> desc_ (phId row)) $ do
        row <- all_ (dbPrHistory prDb)
        guard_ (phExercise row ==. val_ (exerciseName exercise))
        pure row
  pure [(phWeightKg row, phRecordedAt row, phNotes row) | row <- rows]

-- | Read the last sync time from sync_meta, if any.
getLastSyncTime :: Connection -> IO (Maybe UTCTime)
getLastSyncTime conn = do
  result <- runBeamSqlite conn $
    runSelectReturningOne $ select $ do
      row <- all_ (dbSyncMeta prDb)
      guard_ (smKey row ==. val_ "last_sync_time")
      pure row
  pure $ case result of
    Just row -> Just (read (unpack (smValue row)))
    Nothing  -> Nothing

-- | Write the last sync time to sync_meta.
setLastSyncTime :: Connection -> UTCTime -> IO ()
setLastSyncTime conn syncTimestamp = do
  let timeText = pack (show syncTimestamp)
  runBeamSqlite conn $
    runInsert $ insertOnConflict (dbSyncMeta prDb)
      (insertExpressions [SyncMeta (val_ "last_sync_time") (val_ timeText)])
      (conflictingFields smKey)
      (onConflictUpdateSet (\fields _excluded ->
        smValue fields <-. val_ timeText))

-- | Get all history entries recorded after the given time.
getHistorySince :: Connection -> UTCTime -> IO [(Exercise, Double, UTCTime, Maybe Text)]
getHistorySince conn since = do
  rows <- runBeamSqlite conn $
    runSelectReturningList $ select $
      orderBy_ (\row -> asc_ (phId row)) $ do
        row <- all_ (dbPrHistory prDb)
        guard_ (phRecordedAt row >. val_ (pack (show since)))
        pure row
  pure [ (exercise, phWeightKg row, read (unpack (phRecordedAt row)), phNotes row)
       | row <- rows
       , Just exercise <- [parseExercise (phExercise row)]
       ]

-- | Insert a PR record only if the weight is strictly higher than the existing one.
mergeRecord :: Connection -> Exercise -> Double -> IO ()
mergeRecord conn exercise weight = do
  let name = exerciseName exercise
  existing <- runBeamSqlite conn $
    runSelectReturningOne $ select $ do
      row <- all_ (dbPrRecord prDb)
      guard_ (prExercise row ==. val_ name)
      pure row
  case existing of
    Just row | prWeightKg row >= weight -> pure ()
    _ -> runBeamSqlite conn $
      runInsert $ insertOnConflict (dbPrRecord prDb)
        (insertExpressions [PrRecord (val_ name) (val_ weight)])
        (conflictingFields prExercise)
        (onConflictUpdateSet (\fields _excluded ->
          prWeightKg fields <-. val_ weight))

-- | Insert a history entry if no duplicate exists (same exercise, weight, and timestamp).
mergeHistoryEntry :: Connection -> Exercise -> Double -> UTCTime -> Maybe Text -> IO ()
mergeHistoryEntry conn exercise weight timestamp notes = do
  let name = exerciseName exercise
      timestampStr = pack (show timestamp)
  existing <- runBeamSqlite conn $
    runSelectReturningOne $ select $ do
      row <- all_ (dbPrHistory prDb)
      guard_ (phExercise row ==. val_ name)
      guard_ (phWeightKg row ==. val_ weight)
      guard_ (phRecordedAt row ==. val_ timestampStr)
      pure row
  case existing of
    Just _  -> pure ()
    Nothing -> runBeamSqlite conn $
      runInsert $ insert (dbPrHistory prDb) $
        insertExpressions
          [ PrHistory default_ (val_ name) (val_ weight)
                      (val_ timestampStr) (val_ notes) ]

-- | Delete all PR records for a given exercise (used by tests).
deleteRecordsByExercise :: Connection -> Exercise -> IO ()
deleteRecordsByExercise conn exercise =
  runBeamSqlite conn $
    runDelete $ delete (dbPrRecord prDb)
      (\row -> prExercise row ==. val_ (exerciseName exercise))

-- | Delete all history entries for a given exercise (used by tests).
deleteHistoryByExercise :: Connection -> Exercise -> IO ()
deleteHistoryByExercise conn exercise =
  runBeamSqlite conn $
    runDelete $ delete (dbPrHistory prDb)
      (\row -> phExercise row ==. val_ (exerciseName exercise))

-- | Delete a sync_meta entry by key (used by tests).
deleteSyncMeta :: Connection -> Text -> IO ()
deleteSyncMeta conn metaKey =
  runBeamSqlite conn $
    runDelete $ delete (dbSyncMeta prDb)
      (\row -> smKey row ==. val_ metaKey)

-- | Query history rows matching exercise (used by tests).
queryHistoryByExercise :: Connection -> Exercise -> IO [SQLite.Only Int]
queryHistoryByExercise conn exercise =
  SQLite.query conn
    "SELECT id FROM pr_history WHERE exercise = ?"
    (SQLite.Only (exerciseName exercise))

-- | Query history rows matching exercise, weight, and exact timestamp (used by tests).
queryHistoryByExerciseAndTime :: Connection -> Exercise -> Double -> UTCTime -> IO [SQLite.Only Int]
queryHistoryByExerciseAndTime conn exercise weight timestamp =
  SQLite.query conn
    "SELECT id FROM pr_history WHERE exercise = ? AND weight_kg = ? AND recorded_at = ?"
    (exerciseName exercise, weight, show timestamp)

-- | Insert a raw history entry (used by tests that need specific timestamps).
insertHistory :: Connection -> Exercise -> Double -> UTCTime -> Maybe Text -> IO ()
insertHistory conn exercise weight timestamp notes =
  runBeamSqlite conn $
    runInsert $ insert (dbPrHistory prDb) $
      insertExpressions
        [ PrHistory default_ (val_ (exerciseName exercise)) (val_ weight)
                    (val_ (pack (show timestamp))) (val_ notes) ]
