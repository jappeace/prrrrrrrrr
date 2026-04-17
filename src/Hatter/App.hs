{-# LANGUAGE OverloadedStrings #-}
-- | App registration for the gym PR tracker.
module Hatter.App (mobileApp) where

import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (pack)
import GymTracker.AppState (AppState(..), newAppState)
import GymTracker.Storage (withDatabase, initDB, loadRecords)
import GymTracker.Sync (triggerSync)
import GymTracker.Views (AppActions, appRootView, createAppActions)
import Hatter (ActionState, newActionState, runActionM)
import Hatter.Lifecycle (MobileContext(..), LifecycleEvent(..), platformLog)
import Hatter.Types (MobileApp(..), UserState(..))

-- | Build the gym PR tracker mobile app.
-- The action state is created eagerly, but database initialisation is
-- deferred to the first render — the Android files directory is only
-- available after 'startMobileApp' sets up the platform context.
mobileApp :: IO MobileApp
mobileApp = do
  actionState <- newActionState
  lazyState <- newIORef Nothing
  let initialise :: IO (AppState, AppActions)
      initialise = ensureInitialised actionState lazyState
  pure MobileApp
    { maContext = MobileContext
        { onLifecycle = \event -> do
            platformLog ("Lifecycle: " <> pack (show event))
            case event of
              Create    -> pure ()
              Resume    -> do
                cached <- readIORef lazyState
                case cached of
                  Just (appState, _) -> triggerSync appState
                  Nothing            -> pure ()
              Start     -> pure ()
              Pause     -> pure ()
              Stop      -> pure ()
              Destroy   -> pure ()
              LowMemory -> pure ()
        , onError = \exc -> platformLog ("Error: " <> pack (show exc))
        }
    , maView = \userState -> do
        (appState, appActions) <- initialise
        writeIORef (stHttpState appState) (Just (userHttpState userState))
        appRootView appActions appState
    , maActionState = actionState
    }

-- | Initialise database state on first access, returning the cached
-- pair on subsequent calls.
ensureInitialised :: ActionState -> IORef (Maybe (AppState, AppActions)) -> IO (AppState, AppActions)
ensureInitialised actionState ref = do
  cached <- readIORef ref
  case cached of
    Just pair -> pure pair
    Nothing -> do
      appState <- withDatabase $ \conn -> do
        initDB conn
        records <- loadRecords conn
        newAppState records
      appActions <- runActionM actionState (createAppActions appState)
      let pair = (appState, appActions)
      writeIORef ref (Just pair)
      pure pair
