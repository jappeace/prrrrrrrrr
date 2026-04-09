{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
-- | Bidirectional sync with the pr-sync-api server.
--
-- Uses http-client + aeson directly (no servant-client) to avoid pulling
-- generics-sop / Template Haskell into the Android cross-compilation,
-- where the iserv-proxy-interpreter cannot run.
--
-- Runs asynchronously via 'forkIO' so it never blocks the UI.
-- Network errors are caught and logged — the app remains fully offline-capable.
module GymTracker.Sync
  ( triggerSync
  )
where

import Control.Concurrent (forkIO)
import Control.Exception (SomeException, catch)
import Data.Aeson (FromJSON, ToJSON, encode, eitherDecode)
import Data.IORef (writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text, pack)
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Database.SQLite.Simple (Connection)
import GHC.Generics (Generic)
import GymTracker.Config (serverBaseUrl, apiKey)
import GymTracker.Model
  ( AppState(..)
  , exerciseName
  , parseExercise
  )
import GymTracker.Storage
  ( withDatabase
  , loadRecords
  , getLastSyncTime
  , setLastSyncTime
  , getHistorySince
  , mergeRecord
  , mergeHistoryEntry
  )
import HaskellMobile.Lifecycle (platformLog)
import Network.HTTP.Client
  ( httpLbs
  , method
  , newManager
  , parseRequest
  , requestBody
  , requestHeaders
  , responseBody
  , responseStatus
  , RequestBody(RequestBodyLBS)
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)

------------------------------------------------------------------------
-- API types — mirror pr-sync-api's JSON schema.
-- Field names match exactly so Generic-derived aeson instances are compatible.
------------------------------------------------------------------------

data CurrentRecord = CurrentRecord
  { recordExercise :: Text
  , recordWeightKg :: Double
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data HistoryEntry = HistoryEntry
  { historyExercise   :: Text
  , historyWeightKg   :: Double
  , historyRecordedAt :: UTCTime
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data SyncRequest = SyncRequest
  { syncLastSyncTime   :: UTCTime
  , syncCurrentRecords :: [CurrentRecord]
  , syncHistory        :: [HistoryEntry]
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data SyncResponse = SyncResponse
  { syncedCurrentRecords :: [CurrentRecord]
  , syncedHistory        :: [HistoryEntry]
  , syncTime             :: UTCTime
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data FullState = FullState
  { fullCurrentRecords :: [CurrentRecord]
  , fullHistory        :: [HistoryEntry]
  , fullSyncTime       :: UTCTime
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Decide between full or incremental sync, run in a background thread.
-- All exceptions are caught and logged — sync failure never crashes the app.
triggerSync :: AppState -> IO ()
triggerSync appState = do
  _ <- forkIO $
    syncAction appState
      `catch` \(exc :: SomeException) ->
        platformLog ("Sync error: " <> pack (show exc))
  pure ()

-- | Perform sync: full sync if no last sync time, incremental otherwise.
syncAction :: AppState -> IO ()
syncAction appState = do
  manager <- newManager tlsManagerSettings
  withDatabase $ \conn -> do
    lastSync <- getLastSyncTime conn
    case lastSync of
      Nothing -> do
        platformLog "Sync: first boot, fetching full state"
        reqInit <- parseRequest (serverBaseUrl <> "/api/records")
        let req = reqInit
              { requestHeaders = [("X-Api-Key", TE.encodeUtf8 apiKey)]
              }
        resp <- httpLbs req manager
        case statusCode (responseStatus resp) of
          200 -> case eitherDecode (responseBody resp) of
            Right fullState -> do
              mergeFullState conn appState fullState
              platformLog "Sync: full state merged"
            Left decodeErr ->
              platformLog ("Sync GET /api/records decode error: " <> pack decodeErr)
          code ->
            platformLog ("Sync GET /api/records failed with status " <> pack (show code))
      Just since -> do
        platformLog "Sync: incremental sync"
        records <- loadRecords conn
        historySince <- getHistorySince conn since
        let currentRecords = map (\(exercise, weight) ->
              CurrentRecord
                { recordExercise = exerciseName exercise
                , recordWeightKg = weight
                }) (Map.toList records)
            historyEntries = map (\(exercise, weight, timestamp) ->
              HistoryEntry
                { historyExercise = exerciseName exercise
                , historyWeightKg = weight
                , historyRecordedAt = timestamp
                }) historySince
            syncReq = SyncRequest
              { syncLastSyncTime = since
              , syncCurrentRecords = currentRecords
              , syncHistory = historyEntries
              }
        reqInit <- parseRequest (serverBaseUrl <> "/api/sync")
        let req = reqInit
              { method = "POST"
              , requestHeaders =
                  [ ("X-Api-Key", TE.encodeUtf8 apiKey)
                  , ("Content-Type", "application/json")
                  ]
              , requestBody = RequestBodyLBS (encode syncReq)
              }
        resp <- httpLbs req manager
        case statusCode (responseStatus resp) of
          200 -> case eitherDecode (responseBody resp) of
            Right syncResp -> do
              mergeSyncResponse conn appState syncResp
              platformLog "Sync: incremental merge done"
            Left decodeErr ->
              platformLog ("Sync POST /api/sync decode error: " <> pack decodeErr)
          code ->
            platformLog ("Sync POST /api/sync failed with status " <> pack (show code))

-- | Merge a full state dump from the server into local DB and IORefs.
mergeFullState :: Connection -> AppState -> FullState -> IO ()
mergeFullState conn appState fullState = do
  mapM_ (\cr -> case parseExercise (recordExercise cr) of
    Just exercise -> mergeRecord conn exercise (recordWeightKg cr)
    Nothing       -> pure ()
    ) (fullCurrentRecords fullState)
  mapM_ (\he -> case parseExercise (historyExercise he) of
    Just exercise -> mergeHistoryEntry conn exercise (historyWeightKg he) (historyRecordedAt he)
    Nothing       -> pure ()
    ) (fullHistory fullState)
  setLastSyncTime conn (fullSyncTime fullState)
  refreshRecordsIORef conn appState

-- | Merge an incremental sync response into local DB and IORefs.
mergeSyncResponse :: Connection -> AppState -> SyncResponse -> IO ()
mergeSyncResponse conn appState syncResp = do
  mapM_ (\cr -> case parseExercise (recordExercise cr) of
    Just exercise -> mergeRecord conn exercise (recordWeightKg cr)
    Nothing       -> pure ()
    ) (syncedCurrentRecords syncResp)
  mapM_ (\he -> case parseExercise (historyExercise he) of
    Just exercise -> mergeHistoryEntry conn exercise (historyWeightKg he) (historyRecordedAt he)
    Nothing       -> pure ()
    ) (syncedHistory syncResp)
  setLastSyncTime conn (syncTime syncResp)
  refreshRecordsIORef conn appState

-- | Reload records from DB into the AppState IORef so the UI reflects merged data.
refreshRecordsIORef :: Connection -> AppState -> IO ()
refreshRecordsIORef conn appState = do
  records <- loadRecords conn
  writeIORef (stRecords appState) records
