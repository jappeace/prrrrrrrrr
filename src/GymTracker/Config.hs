{-# LANGUAGE OverloadedStrings #-}
-- | Build-time configuration for the gym PR tracker.
-- The API key placeholder is replaced by install scripts before building.
module GymTracker.Config
  ( serverBaseUrl
  , apiKey
  )
where

import Data.Text (Text)

-- | Base URL for the PR sync server.
serverBaseUrl :: String
serverBaseUrl = "https://pr.jappie.me"

-- | API key for authenticating with the sync server.
-- The placeholder is replaced by install.sh / install-wear.sh at build time.
apiKey :: Text
apiKey = "PRRRRRRRRR_API_KEY"
