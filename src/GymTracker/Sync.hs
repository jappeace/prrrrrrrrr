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

import Control.Concurrent (forkIO)
import Control.Exception (SomeException, catch)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy(..))
import Data.Text (Text, pack)
import GymTracker.Config (serverBaseUrl, apiKey)
import GymTracker.AppState (AppState(..))
import GymTracker.Model (exerciseName, parseExercise)
import GymTracker.ServantNative (NativeClientM, runNativeClientM, mkNativeClientEnv)
import GymTracker.Storage
  ( SqlPersistM
  , withDatabase
  , loadRecords
  , getLastSyncTime
  , setLastSyncTime
  , getHistorySince
  , mergeRecord
  , mergeHistoryEntry
  )
import HaskellMobile.Http (HttpState)
import HaskellMobile.Lifecycle (platformLog)
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

-- | Decide between full or incremental sync, run in a background thread.
-- Reads 'HttpState' from the 'AppState' IORef; skips if not yet available.
-- All exceptions are caught and logged — sync failure never crashes the app.
triggerSync :: AppState -> IO ()
triggerSync appState = do
  maybeHttp <- readIORef (stHttpState appState)
  case maybeHttp of
    Nothing -> platformLog "Sync skipped: HTTP not ready"
    Just httpState -> do
      _ <- forkIO $
        syncAction appState httpState
          `catch` \(exc :: SomeException) ->
            platformLog ("Sync error: " <> pack (show exc))
      pure ()

-- | Perform sync: full sync if no last sync time, incremental otherwise.
syncAction :: AppState -> HttpState -> IO ()
syncAction appState httpState = do
  baseUrl <- parseBaseUrl serverBaseUrl
  let clientEnv = mkNativeClientEnv httpState baseUrl
  withDatabase $ do
    lastSync <- getLastSyncTime
    case lastSync of
      Nothing -> do
        liftIO $ platformLog "Sync: first boot, fetching full state"
        result <- liftIO $ runNativeClientM (recordsClient apiKey) clientEnv
        case result of
          Left err -> liftIO $ platformLog ("Sync GET /api/records failed: " <> pack (show err))
          Right fullState -> do
            mergeFullState appState fullState
            liftIO $ platformLog "Sync: full state merged"
      Just since -> do
        liftIO $ platformLog "Sync: incremental sync"
        records <- loadRecords
        historySince <- getHistorySince since
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
        result <- liftIO $ runNativeClientM (syncClient apiKey syncReq) clientEnv
        case result of
          Left err -> liftIO $ platformLog ("Sync POST /api/sync failed: " <> pack (show err))
          Right syncResp -> do
            mergeSyncResponse appState syncResp
            liftIO $ platformLog "Sync: incremental merge done"

-- | Merge a full state dump from the server into local DB and IORefs.
mergeFullState :: AppState -> FullState -> SqlPersistM ()
mergeFullState appState fullState = do
  mapM_ (\cr -> case parseExercise (recordExercise cr) of
    Just exercise -> mergeRecord exercise (recordWeightKg cr)
    Nothing       -> pure ()
    ) (fullCurrentRecords fullState)
  mapM_ (\he -> case parseExercise (historyExercise he) of
    Just exercise -> mergeHistoryEntry exercise (historyWeightKg he) (historyRecordedAt he) (historyNotes he)
    Nothing       -> pure ()
    ) (fullHistory fullState)
  setLastSyncTime (fullSyncTime fullState)
  refreshRecordsIORef appState

-- | Merge an incremental sync response into local DB and IORefs.
mergeSyncResponse :: AppState -> SyncResponse -> SqlPersistM ()
mergeSyncResponse appState syncResp = do
  mapM_ (\cr -> case parseExercise (recordExercise cr) of
    Just exercise -> mergeRecord exercise (recordWeightKg cr)
    Nothing       -> pure ()
    ) (syncedCurrentRecords syncResp)
  mapM_ (\he -> case parseExercise (historyExercise he) of
    Just exercise -> mergeHistoryEntry exercise (historyWeightKg he) (historyRecordedAt he) (historyNotes he)
    Nothing       -> pure ()
    ) (syncedHistory syncResp)
  setLastSyncTime (syncTime syncResp)
  refreshRecordsIORef appState

-- | Reload records from DB into the AppState IORef so the UI reflects merged data.
refreshRecordsIORef :: AppState -> SqlPersistM ()
refreshRecordsIORef appState = do
  records <- loadRecords
  liftIO $ writeIORef (stRecords appState) records
