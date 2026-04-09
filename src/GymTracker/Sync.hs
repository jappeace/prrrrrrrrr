{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Bidirectional sync with the pr-sync-api server.
--
-- Runs asynchronously via 'forkIO' so it never blocks the UI.
-- Network errors are caught and logged — the app remains fully offline-capable.
module GymTracker.Sync
  ( triggerSync
  )
where

import Control.Concurrent (forkIO)
import Control.Exception (SomeException, catch)
import Data.IORef (writeIORef)
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy(..))
import Data.Text (Text, pack)
import Database.SQLite.Simple (Connection)
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
import Network.HTTP.Client (newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import PrSyncApi
  ( ServerApi
  , CurrentRecord(..)
  , HistoryEntry(..)
  , SyncRequest(..)
  , SyncResponse(..)
  , FullState(..)
  )
import Servant.API ((:<|>)(..))
import Servant.Client (ClientM, client, mkClientEnv, parseBaseUrl, runClientM)

-- | Servant client functions derived from the API type.
_healthClient :: ClientM Text
syncClient :: Text -> SyncRequest -> ClientM SyncResponse
recordsClient :: Text -> ClientM FullState
_healthClient :<|> syncClient :<|> recordsClient = client (Proxy @ServerApi)

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
  baseUrl <- parseBaseUrl serverBaseUrl
  let clientEnv = mkClientEnv manager baseUrl
  withDatabase $ \conn -> do
    lastSync <- getLastSyncTime conn
    case lastSync of
      Nothing -> do
        platformLog "Sync: first boot, fetching full state"
        result <- runClientM (recordsClient apiKey) clientEnv
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
        result <- runClientM (syncClient apiKey syncReq) clientEnv
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
