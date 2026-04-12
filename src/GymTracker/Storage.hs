{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Wno-orphans #-}
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
  , EntityField
  , PersistField(..)
  , PersistValue(..)
  , SelectOpt(..)
  , Unique
  , (=.)
  , (==.)
  , (>.)
  , getBy
  , insert_
  , selectFirst
  , selectList
  , upsertBy
  )
import Database.Persist.Sql (PersistFieldSql(..), SqlPersistM, SqlType(..), runMigration)
import Database.Persist.Sqlite (runSqlite)
import Database.Persist.TH (mkMigrate, mkPersist, persistLowerCase, share, sqlSettings)
import Foreign.C.String (CString, peekCString)
import GymTracker.Model (Exercise(..), exerciseName, parseExercise)

foreign import ccall "get_app_files_dir"
  c_get_app_files_dir :: IO CString

-- | PersistField instance for Exercise — serialised as its human-readable name.
instance PersistField Exercise where
  toPersistValue = PersistText . exerciseName
  fromPersistValue (PersistText t) = case parseExercise t of
    Just exercise -> Right exercise
    Nothing       -> Left ("Unknown exercise: " <> t)
  fromPersistValue other = Left ("Expected PersistText for Exercise, got: " <> pack (show other))

instance PersistFieldSql Exercise where
  sqlType _ = SqlString

share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistLowerCase|
PrRecord
  exercise Exercise
  weightKg Double
  UniqueExercise exercise

PrHistory
  exercise Exercise
  weightKg Double
  recordedAt UTCTime

SyncMeta
  key Text
  value Text
  UniqueSyncKey key
|]

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
saveRecord :: Exercise -> Double -> SqlPersistM ()
saveRecord exercise weight = do
  _ <- upsertBy (UniqueExercise exercise)
    (PrRecord exercise weight)
    [PrRecordWeightKg =. weight]
  now <- liftIO getCurrentTime
  insert_ $ PrHistory exercise weight now

-- | Load all history entries for an exercise, newest first.
loadExerciseHistory :: Exercise -> SqlPersistM [(Double, Text)]
loadExerciseHistory exercise = do
  entities <- selectList [PrHistoryExercise ==. exercise] [Desc PrHistoryId]
  pure [ (prHistoryWeightKg (entityVal entity), pack (show (prHistoryRecordedAt (entityVal entity))))
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
getHistorySince :: UTCTime -> SqlPersistM [(Exercise, Double, UTCTime)]
getHistorySince since = do
  entities <- selectList [PrHistoryRecordedAt >. since] [Asc PrHistoryId]
  pure [ (prHistoryExercise (entityVal entity), prHistoryWeightKg (entityVal entity), prHistoryRecordedAt (entityVal entity))
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
mergeHistoryEntry :: Exercise -> Double -> UTCTime -> SqlPersistM ()
mergeHistoryEntry exercise weight timestamp = do
  existing <- selectFirst
    [ PrHistoryExercise ==. exercise
    , PrHistoryWeightKg ==. weight
    , PrHistoryRecordedAt ==. timestamp
    ] []
  case existing of
    Just _  -> pure ()
    Nothing -> insert_ $ PrHistory exercise weight timestamp
