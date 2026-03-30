{-# LANGUAGE OverloadedStrings #-}
-- | Mobile entry point for prrrrrrrrr.
--
-- Registers the gym tracker app so all FFI exports can find it.
-- The platform bridge (Android JNI, iOS Swift) runs this @main@
-- after @hs_init@ via the RTS API.
module Main where

import HaskellMobile (runMobileApp, platformLog)
import HaskellMobile.App (mobileApp)

main :: IO ()
main = do
  runMobileApp mobileApp
  platformLog "prrrrrrrrr app registered"
