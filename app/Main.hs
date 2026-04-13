module Main where

import Hatter (platformLog, startMobileApp)
import Hatter.AppContext (AppContext(..), derefAppContext)
import Hatter.Lifecycle (LifecycleEvent(..), MobileContext(onLifecycle))
import Hatter.App (mobileApp)

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
