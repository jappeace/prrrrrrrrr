{-# LANGUAGE OverloadedStrings #-}
-- | App registration for the gym PR tracker.
module HaskellMobile.App (mobileApp) where

import Data.Text (pack)
import GymTracker.Model (AppState, newAppState)
import GymTracker.Storage (withDatabase, initDB, loadRecords)
import GymTracker.Sync (triggerSync)
import GymTracker.Views (appRootView)
import HaskellMobile.Lifecycle (MobileContext(..), LifecycleEvent(..), platformLog)
import HaskellMobile.Types (MobileApp(..))
import System.IO.Unsafe (unsafePerformIO)

-- | The gym PR tracker mobile app.
mobileApp :: MobileApp
mobileApp = MobileApp
  { maContext = syncMobileContext
  , maView = \_userState -> appRootView globalState
  }

-- | MobileContext that logs lifecycle events and triggers sync on Create/Resume.
syncMobileContext :: MobileContext
syncMobileContext = MobileContext
  { onLifecycle = \event -> do
      platformLog ("Lifecycle: " <> pack (show event))
      case event of
        Create -> triggerSync globalState
        Resume -> triggerSync globalState
        Start    -> pure ()
        Pause    -> pure ()
        Stop     -> pure ()
        Destroy  -> pure ()
        LowMemory -> pure ()
  , onError = \exc -> platformLog ("Error: " <> pack (show exc))
  }

-- | Global application state, initialized once on first access.
-- Opens the SQLite database, creates the table, and loads existing records.
globalState :: AppState
globalState = unsafePerformIO $ do
  records <- withDatabase $ \db -> do
    initDB db
    loadRecords db
  newAppState records
{-# NOINLINE globalState #-}
