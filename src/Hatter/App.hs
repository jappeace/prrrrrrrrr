{-# LANGUAGE OverloadedStrings #-}
-- | App registration for the gym PR tracker.
module Hatter.App (mobileApp) where

import Data.IORef (readIORef, writeIORef)
import Data.Text (pack)
import GymTracker.AppState (AppState(..), newAppState)
import GymTracker.Storage (withDatabase, initDB, loadRecords)
import GymTracker.Sync (triggerSync)
import GymTracker.Views (AppActions, appRootView, createAppActions)
import Hatter (ActionState, newActionState, runActionM)
import Hatter.Lifecycle (MobileContext(..), LifecycleEvent(..), platformLog)
import Hatter.Types (MobileApp(..), UserState(..))
import System.IO.Unsafe (unsafePerformIO)

-- | The gym PR tracker mobile app.
mobileApp :: MobileApp
mobileApp = MobileApp
  { maContext = syncMobileContext
  , maView = \userState -> do
      -- Capture HttpState from the framework on every render.
      writeIORef (stHttpState globalState) (Just (userHttpState userState))
      -- On first render, trigger boot sync (HttpState wasn't available at Create).
      needsBoot <- readIORef (stNeedsSyncOnBoot globalState)
      case needsBoot of
        True -> do
          writeIORef (stNeedsSyncOnBoot globalState) False
          triggerSync globalState
        False -> pure ()
      appRootView globalAppActions globalState
  , maActionState = globalActionState
  }

-- | MobileContext that logs lifecycle events and triggers sync on Resume.
-- Boot sync is handled by the first render (see 'maView') because
-- 'HttpState' is not yet available during the 'Create' lifecycle event.
syncMobileContext :: MobileContext
syncMobileContext = MobileContext
  { onLifecycle = \event -> do
      platformLog ("Lifecycle: " <> pack (show event))
      case event of
        Create    -> pure ()
        Resume    -> triggerSync globalState
        Start     -> pure ()
        Pause     -> pure ()
        Stop      -> pure ()
        Destroy   -> pure ()
        LowMemory -> pure ()
  , onError = \exc -> platformLog ("Error: " <> pack (show exc))
  }

-- | Global application state, initialized once on first access.
-- Opens the SQLite database, creates the table, and loads existing records.
globalState :: AppState
globalState = unsafePerformIO $ do
  records <- withDatabase $ \conn -> do
    initDB conn
    loadRecords conn
  newAppState records
{-# NOINLINE globalState #-}

-- | Global action state for callback handle registration.
globalActionState :: ActionState
globalActionState = unsafePerformIO newActionState
{-# NOINLINE globalActionState #-}

-- | Pre-created callback handles for the entire UI.
globalAppActions :: AppActions
globalAppActions = unsafePerformIO $
  runActionM globalActionState (createAppActions globalState)
{-# NOINLINE globalAppActions #-}
