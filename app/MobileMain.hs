module Main where

import HaskellMobile (runMobileApp, platformLog)
import HaskellMobile.App (mobileApp)

main :: IO ()
main = do
  runMobileApp mobileApp
  platformLog "prrrrrrrrr registered"
