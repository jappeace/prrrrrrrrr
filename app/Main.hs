module Main where

import HaskellMobile (appContext, platformLog)
import HaskellMobile.Lifecycle (LifecycleEvent(..), MobileContext(onLifecycle))

-- | Desktop entry point: simulates lifecycle and renders UI.
main :: IO ()
main = do
  platformLog "prrrrrrrrr starting..."
  let listen = onLifecycle appContext
  listen Create
  listen Start
  listen Resume
  platformLog "prrrrrrrrr running"
