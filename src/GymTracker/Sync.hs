{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Bidirectional sync with the pr-sync-api server.
--
-- Uses 'NativeClientM' from "GymTracker.ServantNative" to route HTTP
-- requests through the platform's native HTTP stack, avoiding the
-- ~90 MB of TLS\/crypto C dependencies that @http-client-tls@ brings.
--
-- Runs asynchronously via 'forkIO' so it never blocks the UI.
-- Network errors are caught and logged — the app remains fully offline-capable.
module GymTracker.Sync
  ( triggerSync
  )
where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (tryTakeMVar, putMVar)
import Control.Exception (SomeException, catch, finally)
import Data.IORef (readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy(..))
import Data.Text (Text, pack)
import Database.SQLite.Simple (Connection)
import GymTracker.Config (serverBaseUrl, apiKey)
import GymTracker.AppState (AppState(..))
import GymTracker.Model (exerciseName, parseExercise)
import GymTracker.ServantNative (NativeClientM, runNativeClientM, mkNativeClientEnv)
import GymTracker.Storage
  ( withDatabase
  , loadRecords
  , getLastSyncTime
  , setLastSyncTime
  , getHistorySince
  , mergeRecord
  , mergeHistoryEntry
  )
import Hatter.Http (HttpState)
import Hatter.Lifecycle (platformLog)
import PrSyncApi
  ( ServerApi
  , CurrentRecord(..)
  , HistoryEntry(..)
  , SyncRequest(..)
  , SyncResponse(..)
  , FullState(..)
  )
import Servant.API ((:<|>)(..))
import Servant.Client.Core (clientIn, parseBaseUrl)

-- | Servant client functions derived from the API type via 'NativeClientM'.
_healthClient :: NativeClientM Text
syncClient :: Text -> SyncRequest -> NativeClientM SyncResponse
recordsClient :: Text -> NativeClientM FullState
_healthClient :<|> syncClient :<|> recordsClient =
  clientIn (Proxy @ServerApi) (Proxy @NativeClientM)

-- | Trigger a sync in a background thread.
-- Waits for 'HttpState' to become available (polling every 100ms),
-- then runs the sync. Uses an 'MVar' lock to ensure only one sync
-- runs at a time — concurrent calls are silently dropped.
triggerSync :: AppState -> IO ()
triggerSync appState = do
  acquired <- tryTakeMVar (stSyncLock appState)
  case acquired of
    Nothing -> platformLog "Sync skipped: already in progress"
    Just () -> do
      _ <- forkIO $
        (do httpState <- waitForHttp appState
            syncAction appState httpState)
          `catch` (\(exc :: SomeException) ->
            platformLog ("Sync error: " <> pack (show exc)))
          `finally` putMVar (stSyncLock appState) ()
      pure ()

-- | Poll 'stHttpState' every 100ms until it becomes 'Just'.
waitForHttp :: AppState -> IO HttpState
waitForHttp appState = do
  maybeHttp <- readIORef (stHttpState appState)
  case maybeHttp of
    Just httpState -> pure httpState
    Nothing -> do
      threadDelay 100_000
      waitForHttp appState

-- | Perform sync: full sync if no last sync time, incremental otherwise.
syncAction :: AppState -> HttpState -> IO ()
syncAction appState httpState = do
  baseUrl <- parseBaseUrl serverBaseUrl
  let clientEnv = mkNativeClientEnv httpState baseUrl
  withDatabase $ \conn -> do
    lastSync <- getLastSyncTime conn
    case lastSync of
      Nothing -> do
        platformLog "Sync: first boot, fetching full state"
        result <- runNativeClientM (recordsClient apiKey) clientEnv
        case result of
          Left err -> platformLog ("Sync GET /api/records failed: " <> pack (show err))
          Right fullState -> do
            mergeFullState conn appState fullState
            platformLog "Sync: full state merged"
      Just since -> do
        platformLog "Sync: incremental sync"
        records <- loadRecords conn
        historySince <- getHistorySince conn since
        let currentRecords = map (\(exercise, weight) ->
              CurrentRecord
                { recordExercise = exerciseName exercise
                , recordWeightKg = weight
                }) (Map.toList records)
            historyEntries = map (\(exercise, weight, timestamp, notes) ->
              HistoryEntry
                { historyExercise = exerciseName exercise
                , historyWeightKg = weight
                , historyRecordedAt = timestamp
                , historyNotes = notes
                }) historySince
            syncReq = SyncRequest
              { syncLastSyncTime = since
              , syncCurrentRecords = currentRecords
              , syncHistory = historyEntries
              }
        result <- runNativeClientM (syncClient apiKey syncReq) clientEnv
        case result of
          Left err -> platformLog ("Sync POST /api/sync failed: " <> pack (show err))
          Right syncResp -> do
            mergeSyncResponse conn appState syncResp
            platformLog "Sync: incremental merge done"

-- | Merge a full state dump from the server into local DB and IORefs.
mergeFullState :: Connection -> AppState -> FullState -> IO ()
mergeFullState conn appState fullState = do
  mapM_ (\cr -> case parseExercise (recordExercise cr) of
    Just exercise -> mergeRecord conn exercise (recordWeightKg cr)
    Nothing       -> pure ()
    ) (fullCurrentRecords fullState)
  mapM_ (\he -> case parseExercise (historyExercise he) of
    Just exercise -> mergeHistoryEntry conn exercise (historyWeightKg he) (historyRecordedAt he) (historyNotes he)
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
    Just exercise -> mergeHistoryEntry conn exercise (historyWeightKg he) (historyRecordedAt he) (historyNotes he)
    Nothing       -> pure ()
    ) (syncedHistory syncResp)
  setLastSyncTime conn (syncTime syncResp)
  refreshRecordsIORef conn appState

-- | Reload records from DB into the AppState IORef so the UI reflects merged data.
refreshRecordsIORef :: Connection -> AppState -> IO ()
refreshRecordsIORef conn appState = do
  records <- loadRecords conn
  writeIORef (stRecords appState) records
