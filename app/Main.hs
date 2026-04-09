module Main where

import HaskellMobile (platformLog, startMobileApp, AppContext(..), derefAppContext)
import HaskellMobile.Lifecycle (LifecycleEvent(..), MobileContext(onLifecycle))
import HaskellMobile.App (mobileApp)

-- | Desktop entry point: registers the app, simulates lifecycle.
main :: IO ()
main = do
  ctxPtr <- startMobileApp mobileApp
  platformLog "prrrrrrrrr starting..."
  appCtx <- derefAppContext ctxPtr
  let listen = onLifecycle (acMobileContext appCtx)
  listen Create
  listen Start
  listen Resume
  platformLog "prrrrrrrrr running"
