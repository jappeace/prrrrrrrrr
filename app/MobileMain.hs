{-# LANGUAGE OverloadedStrings #-}
-- | Mobile entry point for prrrrrrrrr.
--
-- Returns the AppContext pointer to the platform bridge.
-- The platform bridge (Android JNI, iOS Swift) runs this @main@
-- after @hs_init@ via the RTS API.
module Main where

import Foreign.Ptr (Ptr)
import Hatter (startMobileApp, platformLog)
import Hatter.AppContext (AppContext)
import Hatter.App (mobileApp, globalState)
import GymTracker.Sync (triggerSync)

main :: IO (Ptr AppContext)
main = do
  platformLog "prrrrrrrrr app registered"
  appCtxPtr <- startMobileApp mobileApp
  triggerSync globalState
  pure appCtxPtr
