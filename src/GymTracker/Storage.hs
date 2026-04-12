{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ImportQualifiedPost #-}
-- | Persistent-backed storage for PR records.
--
-- Uses persistent + persistent-sqlite for type-safe database access.
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
  , SqlPersistM
  , PrRecord(..)
  , PrHistory(..)
  , SyncMeta(..)
  , EntityField(..)
  , Unique(..)
  )
where

import Control.Monad.IO.Class (liftIO)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text, pack, unpack)
import Data.Time (UTCTime, getCurrentTime)
import Database.Persist
  ( Entity(..)
  , SelectOpt(..)
  , (=.)
  , (==.)
  , (>.)
  , getBy
  , insert_
  , selectFirst
  , selectList
  , upsertBy
  )
import Database.Persist.Sql (SqlPersistM, runMigration)
import Database.Persist.Sqlite (runSqlite)
import Foreign.C.String (CString, peekCString)
import GymTracker.Model (Exercise(..))
import GymTracker.Schema
  ( PrRecord(..)
  , PrHistory(..)
  , SyncMeta(..)
  , EntityField(..)
  , Unique(..)
  , migrateAll
  )

foreign import ccall "get_app_files_dir"
  c_get_app_files_dir :: IO CString

-- | Get the database file path.
getDbPath :: IO FilePath
getDbPath = do
  dir <- c_get_app_files_dir >>= peekCString
  pure (dir ++ "/prrrrrrrrr.db")

-- | Open the database, run a persistent action, then close it.
withDatabase :: SqlPersistM a -> IO a
withDatabase action = do
  path <- getDbPath
  runSqlite (pack path) action

-- | Run database migrations.
initDB :: SqlPersistM ()
initDB = runMigration migrateAll

-- | Load all PR records from the database.
loadRecords :: SqlPersistM (Map Exercise Double)
loadRecords = do
  entities <- selectList [] []
  pure $ Map.fromList
    [ (prRecordExercise (entityVal entity), prRecordWeightKg (entityVal entity))
    | entity <- entities
    ]

-- | Save a single PR record (upsert) and append to history.
saveRecord :: Exercise -> Double -> Maybe Text -> SqlPersistM ()
saveRecord exercise weight notes = do
  _ <- upsertBy (UniqueExercise exercise)
    (PrRecord exercise weight)
    [PrRecordWeightKg =. weight]
  now <- liftIO getCurrentTime
  insert_ $ PrHistory exercise weight now notes

-- | Load all history entries for an exercise, newest first.
loadExerciseHistory :: Exercise -> SqlPersistM [(Double, Text, Maybe Text)]
loadExerciseHistory exercise = do
  entities <- selectList [PrHistoryExercise ==. exercise] [Desc PrHistoryId]
  pure [ (prHistoryWeightKg (entityVal entity), pack (show (prHistoryRecordedAt (entityVal entity))), prHistoryNotes (entityVal entity))
       | entity <- entities
       ]

-- | Read the last sync time from sync_meta, if any.
getLastSyncTime :: SqlPersistM (Maybe UTCTime)
getLastSyncTime = do
  result <- getBy (UniqueSyncKey "last_sync_time")
  pure $ case result of
    Just entity -> Just (read (unpack (syncMetaValue (entityVal entity))))
    Nothing     -> Nothing

-- | Write the last sync time to sync_meta.
setLastSyncTime :: UTCTime -> SqlPersistM ()
setLastSyncTime syncTimestamp = do
  _ <- upsertBy (UniqueSyncKey "last_sync_time")
    (SyncMeta "last_sync_time" (pack (show syncTimestamp)))
    [SyncMetaValue =. pack (show syncTimestamp)]
  pure ()

-- | Get all history entries recorded after the given time.
getHistorySince :: UTCTime -> SqlPersistM [(Exercise, Double, UTCTime, Maybe Text)]
getHistorySince since = do
  entities <- selectList [PrHistoryRecordedAt >. since] [Asc PrHistoryId]
  pure [ (prHistoryExercise (entityVal entity), prHistoryWeightKg (entityVal entity), prHistoryRecordedAt (entityVal entity), prHistoryNotes (entityVal entity))
       | entity <- entities
       ]

-- | Insert a PR record only if the weight is strictly higher than the existing one.
mergeRecord :: Exercise -> Double -> SqlPersistM ()
mergeRecord exercise weight = do
  existing <- getBy (UniqueExercise exercise)
  case existing of
    Just entity | prRecordWeightKg (entityVal entity) >= weight -> pure ()
    Just _  -> do
      _ <- upsertBy (UniqueExercise exercise)
        (PrRecord exercise weight)
        [PrRecordWeightKg =. weight]
      pure ()
    Nothing -> do
      _ <- upsertBy (UniqueExercise exercise)
        (PrRecord exercise weight)
        [PrRecordWeightKg =. weight]
      pure ()

-- | Insert a history entry if no duplicate exists (same exercise, weight, and timestamp).
mergeHistoryEntry :: Exercise -> Double -> UTCTime -> Maybe Text -> SqlPersistM ()
mergeHistoryEntry exercise weight timestamp notes = do
  existing <- selectFirst
    [ PrHistoryExercise ==. exercise
    , PrHistoryWeightKg ==. weight
    , PrHistoryRecordedAt ==. timestamp
    ] []
  case existing of
    Just _  -> pure ()
    Nothing -> insert_ $ PrHistory exercise weight timestamp notes
