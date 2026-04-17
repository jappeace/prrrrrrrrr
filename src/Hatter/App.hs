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
-- Platform context (files directory, locale) is already available
-- when this runs — the JNI bridge sets it up before calling main.
mobileApp :: IO MobileApp
mobileApp = do
  actionState <- newActionState
  appState <- withDatabase $ \conn -> do
    initDB conn
    loadRecords conn >>= newAppState
  appActions <- runActionM actionState (createAppActions appState)
  pure MobileApp
    { maContext = MobileContext
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
    , maView = \userState -> do
        writeIORef (stHttpState appState) (Just (userHttpState userState))
        appRootView appActions appState
    , maActionState = actionState
    }
