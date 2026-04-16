{-# LANGUAGE OverloadedStrings #-}
-- | App registration for the gym PR tracker.
module Hatter.App (mobileApp) where

import Data.IORef (writeIORef)
import Data.Text (pack)
import GymTracker.AppState (AppState(..), newAppState)
import GymTracker.Storage (withDatabase, initDB, loadRecords)
import GymTracker.Sync (triggerSync)
import GymTracker.Views (appRootView, createAppActions)
import Hatter (newActionState, runActionM)
import Hatter.Lifecycle (MobileContext(..), LifecycleEvent(..), platformLog)
import Hatter.Types (MobileApp(..), UserState(..))

-- | Build the gym PR tracker mobile app.
-- Initialises the database, loads records, and wires up state via closures
-- instead of top-level unsafePerformIO globals.
mobileApp :: IO MobileApp
mobileApp = do
  actionState <- newActionState
  appState <- withDatabase $ \conn -> do
    initDB conn
    records <- loadRecords conn
    newAppState records
  appActions <- runActionM actionState (createAppActions appState)
  pure MobileApp
    { maContext     = syncMobileContext appState
    , maView        = \userState -> do
        writeIORef (stHttpState appState) (Just (userHttpState userState))
        appRootView appActions appState
    , maActionState = actionState
    }

-- | MobileContext that logs lifecycle events and triggers sync on Resume.
syncMobileContext :: AppState -> MobileContext
syncMobileContext appState = MobileContext
  { onLifecycle = \event -> do
      platformLog ("Lifecycle: " <> pack (show event))
      case event of
        Create    -> pure ()
        Resume    -> triggerSync appState
        Start     -> pure ()
        Pause     -> pure ()
        Stop      -> pure ()
        Destroy   -> pure ()
        LowMemory -> pure ()
  , onError = \exc -> platformLog ("Error: " <> pack (show exc))
  }
