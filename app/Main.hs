module Main where

import HaskellMobile (platformLog, runMobileApp, MobileApp(maContext))
import HaskellMobile.Lifecycle (LifecycleEvent(..), MobileContext(onLifecycle))
import HaskellMobile.App (mobileApp)

-- | Desktop entry point: registers the app, simulates lifecycle.
main :: IO ()
main = do
  runMobileApp mobileApp
  platformLog "prrrrrrrrr starting..."
  let listen = onLifecycle (maContext mobileApp)
  listen Create
  listen Start
  listen Resume
  platformLog "prrrrrrrrr running"
