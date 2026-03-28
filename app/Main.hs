module Main where

import HaskellMobile (runMobileApp, platformLog, MobileApp(maContext))
import HaskellMobile.App (mobileApp)
import HaskellMobile.Lifecycle (LifecycleEvent(..), MobileContext(onLifecycle))

-- | Desktop entry point: registers the app, then simulates lifecycle.
main :: IO ()
main = do
  runMobileApp mobileApp
  platformLog "prrrrrrrrr starting..."
  let listen = onLifecycle (maContext mobileApp)
  listen Create
  listen Start
  listen Resume
  platformLog "prrrrrrrrr running"
