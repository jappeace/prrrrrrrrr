{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# OPTIONS_GHC -Wno-orphans #-}
-- | Persistent schema for the gym PR tracker.
--
-- This module is in the schema package so that the Template Haskell
-- splice runs during the cross-deps build (which has iserv-proxy /
-- -fexternal-interpreter support), rather than during the consumer
-- build (which does not).
module GymTracker.Schema
  ( PrRecord(..)
  , PrHistory(..)
  , SyncMeta(..)
  , EntityField(..)
  , Unique(..)
  , migrateAll
  ) where

import Data.Text (Text, pack)
import Data.Time (UTCTime)
import Database.Persist
  ( EntityField
  , PersistField(..)
  , PersistValue(..)
  , Unique
  )
import Database.Persist.Sql (PersistFieldSql(..), SqlType(..))
import Database.Persist.TH (mkMigrate, mkPersist, persistLowerCase, share, sqlSettings)
import GymTracker.Model (Exercise(..), exerciseName, parseExercise)

-- | PersistField instance for Exercise — serialised as its human-readable name.
instance PersistField Exercise where
  toPersistValue = PersistText . exerciseName
  fromPersistValue (PersistText t) = case parseExercise t of
    Just exercise -> Right exercise
    Nothing       -> Left ("Unknown exercise: " <> t)
  fromPersistValue other = Left ("Expected PersistText for Exercise, got: " <> pack (show other))

instance PersistFieldSql Exercise where
  sqlType _ = SqlString

share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistLowerCase|
PrRecord
  exercise Exercise
  weightKg Double
  UniqueExercise exercise

PrHistory
  exercise Exercise
  weightKg Double
  recordedAt UTCTime

SyncMeta
  key Text
  value Text
  UniqueSyncKey key
|]
