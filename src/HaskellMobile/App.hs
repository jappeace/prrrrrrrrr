{-# LANGUAGE OverloadedStrings #-}
-- | Backpack signature implementation for the gym PR tracker app.
module HaskellMobile.App (appContext, appView) where

import GymTracker.Model (AppState, newAppState)
import GymTracker.Storage (withDatabase, initDB, loadRecords)
import GymTracker.Views (appRootView)
import HaskellMobile.Lifecycle (MobileContext, loggingMobileContext)
import HaskellMobile.Widget (Widget)
import System.IO.Unsafe (unsafePerformIO)

-- | The application context — logs every lifecycle event.
appContext :: MobileContext
appContext = loggingMobileContext

-- | Global application state, initialized once on first access.
-- Opens the SQLite database, creates the table, and loads existing records.
globalState :: AppState
globalState = unsafePerformIO $ do
  records <- withDatabase $ \db -> do
    initDB db
    loadRecords db
  newAppState records
{-# NOINLINE globalState #-}

-- | Build the current UI tree from global state.
appView :: IO Widget
appView = appRootView globalState
