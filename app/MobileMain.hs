{-# LANGUAGE OverloadedStrings #-}
-- | Mobile entry point for prrrrrrrrr.
--
-- Returns the AppContext pointer to the platform bridge.
-- The platform bridge (Android JNI, iOS Swift) runs this @main@
-- after @hs_init@ via the RTS API.
module Main where

import Foreign.Ptr (Ptr)
import HaskellMobile (startMobileApp, platformLog, AppContext)
import HaskellMobile.App (mobileApp)

main :: IO (Ptr AppContext)
main = do
  platformLog "prrrrrrrrr app registered"
  startMobileApp mobileApp
