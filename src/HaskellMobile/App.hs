{-# LANGUAGE OverloadedStrings #-}
-- | App registration for the gym PR tracker.
module HaskellMobile.App (mobileApp) where

import GymTracker.Model (AppState, newAppState)
import GymTracker.Storage (withDatabase, initDB, loadRecords)
import GymTracker.Views (appRootView)
import HaskellMobile.Lifecycle (loggingMobileContext)
import HaskellMobile.Types (MobileApp(..))
import System.IO.Unsafe (unsafePerformIO)

-- | The gym PR tracker mobile app.
mobileApp :: MobileApp
mobileApp = MobileApp
  { maContext = loggingMobileContext
  , maView = appRootView globalState
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
