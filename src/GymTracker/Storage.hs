{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ImportQualifiedPost #-}
-- | SQLite-backed storage for PR records.
--
-- Uses raw FFI bindings to the bundled sqlite3 amalgamation.
-- The database is stored at @get_app_files_dir() ++ "/prrrrrrrrr.db"@.
module GymTracker.Storage
  ( withDatabase
  , initDB
  , loadRecords
  , saveRecord
  , loadExerciseHistory
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text, pack, unpack)
import Foreign.C.String (CString, withCString, peekCString)
import Foreign.C.Types (CInt(..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, nullPtr, FunPtr, nullFunPtr)
import Foreign.Storable (peek)
import GymTracker.Model (Exercise(..), allExercises, exerciseName)
import Data.IORef (IORef, newIORef, readIORef, modifyIORef')

-- | Opaque SQLite database handle.
data Sqlite3
-- | Opaque SQLite statement handle.
data Sqlite3Stmt

-- SQLite FFI
foreign import ccall "sqlite3_open"
  c_sqlite3_open :: CString -> Ptr (Ptr Sqlite3) -> IO CInt

foreign import ccall "sqlite3_close"
  c_sqlite3_close :: Ptr Sqlite3 -> IO CInt

foreign import ccall "sqlite3_exec"
  c_sqlite3_exec :: Ptr Sqlite3 -> CString -> FunPtr () -> Ptr () -> Ptr CString -> IO CInt

foreign import ccall "sqlite3_prepare_v2"
  c_sqlite3_prepare_v2 :: Ptr Sqlite3 -> CString -> CInt -> Ptr (Ptr Sqlite3Stmt) -> Ptr (Ptr ()) -> IO CInt

foreign import ccall "sqlite3_step"
  c_sqlite3_step :: Ptr Sqlite3Stmt -> IO CInt

foreign import ccall "sqlite3_finalize"
  c_sqlite3_finalize :: Ptr Sqlite3Stmt -> IO CInt

foreign import ccall "sqlite3_column_text"
  c_sqlite3_column_text :: Ptr Sqlite3Stmt -> CInt -> IO CString

foreign import ccall "sqlite3_column_double"
  c_sqlite3_column_double :: Ptr Sqlite3Stmt -> CInt -> IO Double

foreign import ccall "sqlite3_bind_text"
  c_sqlite3_bind_text :: Ptr Sqlite3Stmt -> CInt -> CString -> CInt -> Ptr () -> IO CInt

foreign import ccall "sqlite3_bind_double"
  c_sqlite3_bind_double :: Ptr Sqlite3Stmt -> CInt -> Double -> IO CInt

foreign import ccall "get_app_files_dir"
  c_get_app_files_dir :: IO CString

-- | SQLITE_ROW = 100
sqliteRow :: CInt
sqliteRow = 100

-- | Get the database file path.
getDbPath :: IO FilePath
getDbPath = do
  dir <- c_get_app_files_dir >>= peekCString
  pure (dir ++ "/prrrrrrrrr.db")

-- | Open the database, run an action, then close it.
withDatabase :: (Ptr Sqlite3 -> IO a) -> IO a
withDatabase action = do
  path <- getDbPath
  db <- alloca $ \dbPtr -> do
    rc <- withCString path $ \cpath ->
      c_sqlite3_open cpath dbPtr
    if rc /= 0
      then error $ "Failed to open database: " ++ path
      else peek dbPtr
  result <- action db
  _ <- c_sqlite3_close db
  pure result

-- | Create the pr_records and pr_history tables if they don't exist.
initDB :: Ptr Sqlite3 -> IO ()
initDB db = do
  withCString "CREATE TABLE IF NOT EXISTS pr_records (exercise TEXT PRIMARY KEY, weight_kg REAL NOT NULL)" $ \sql -> do
    rc <- c_sqlite3_exec db sql nullFunPtr nullPtr nullPtr
    if rc /= 0
      then error $ "initDB pr_records failed with code: " ++ show rc
      else pure ()
  withCString "CREATE TABLE IF NOT EXISTS pr_history (id INTEGER PRIMARY KEY AUTOINCREMENT, exercise TEXT NOT NULL, weight_kg REAL NOT NULL, recorded_at TEXT NOT NULL DEFAULT (datetime('now')))" $ \sql -> do
    rc <- c_sqlite3_exec db sql nullFunPtr nullPtr nullPtr
    if rc /= 0
      then error $ "initDB pr_history failed with code: " ++ show rc
      else pure ()

-- | Load all PR records from the database.
loadRecords :: Ptr Sqlite3 -> IO (Map Exercise Double)
loadRecords db = do
  ref <- newIORef Map.empty
  alloca $ \stmtPtr -> do
    rc <- withCString "SELECT exercise, weight_kg FROM pr_records" $ \sql ->
      c_sqlite3_prepare_v2 db sql (-1) stmtPtr nullPtr
    if rc /= 0
      then pure Map.empty
      else do
        stmt <- peek stmtPtr
        loadRows stmt ref
        _ <- c_sqlite3_finalize stmt
        readIORef ref
  where
    loadRows :: Ptr Sqlite3Stmt -> IORef (Map Exercise Double) -> IO ()
    loadRows stmt ref = do
      rc <- c_sqlite3_step stmt
      if rc == sqliteRow
        then do
          namePtr <- c_sqlite3_column_text stmt 0
          name <- peekCString namePtr
          weight <- c_sqlite3_column_double stmt 1
          case nameToExercise (pack name) of
            Just ex -> modifyIORef' ref (Map.insert ex weight)
            Nothing -> pure ()  -- skip unknown exercises
          loadRows stmt ref
        else pure ()

-- | Save a single PR record (upsert) and append to history.
-- Uses SQLITE_STATIC for bind — the CString from withCString
-- lives until after sqlite3_step returns, so this is safe.
saveRecord :: Ptr Sqlite3 -> Exercise -> Double -> IO ()
saveRecord db exercise weight = do
  upsertCurrent
  insertHistory
  where
    upsertCurrent :: IO ()
    upsertCurrent =
      alloca $ \stmtPtr -> do
        rc <- withCString "INSERT OR REPLACE INTO pr_records (exercise, weight_kg) VALUES (?, ?)" $ \sql ->
          c_sqlite3_prepare_v2 db sql (-1) stmtPtr nullPtr
        if rc /= 0
          then pure ()
          else do
            stmt <- peek stmtPtr
            withCString (unpack (exerciseName exercise)) $ \cname -> do
              _ <- c_sqlite3_bind_text stmt 1 cname (-1) nullPtr
              _ <- c_sqlite3_bind_double stmt 2 weight
              _ <- c_sqlite3_step stmt
              _ <- c_sqlite3_finalize stmt
              pure ()

    insertHistory :: IO ()
    insertHistory =
      alloca $ \stmtPtr -> do
        rc <- withCString "INSERT INTO pr_history (exercise, weight_kg) VALUES (?, ?)" $ \sql ->
          c_sqlite3_prepare_v2 db sql (-1) stmtPtr nullPtr
        if rc /= 0
          then pure ()
          else do
            stmt <- peek stmtPtr
            withCString (unpack (exerciseName exercise)) $ \cname -> do
              _ <- c_sqlite3_bind_text stmt 1 cname (-1) nullPtr
              _ <- c_sqlite3_bind_double stmt 2 weight
              _ <- c_sqlite3_step stmt
              _ <- c_sqlite3_finalize stmt
              pure ()

-- | Load all history entries for an exercise, newest first.
loadExerciseHistory :: Ptr Sqlite3 -> Exercise -> IO [(Double, Text)]
loadExerciseHistory db exercise = do
  ref <- newIORef []
  alloca $ \stmtPtr -> do
    rc <- withCString "SELECT weight_kg, recorded_at FROM pr_history WHERE exercise = ? ORDER BY id ASC" $ \sql ->
      c_sqlite3_prepare_v2 db sql (-1) stmtPtr nullPtr
    if rc /= 0
      then pure []
      else do
        stmt <- peek stmtPtr
        withCString (unpack (exerciseName exercise)) $ \cname -> do
          _ <- c_sqlite3_bind_text stmt 1 cname (-1) nullPtr
          loadRows stmt ref
        _ <- c_sqlite3_finalize stmt
        readIORef ref
  where
    loadRows :: Ptr Sqlite3Stmt -> IORef [(Double, Text)] -> IO ()
    loadRows stmt ref = do
      rc <- c_sqlite3_step stmt
      if rc == sqliteRow
        then do
          weight    <- c_sqlite3_column_double stmt 0
          tsPtr     <- c_sqlite3_column_text stmt 1
          timestamp <- peekCString tsPtr
          modifyIORef' ref ((weight, pack timestamp) :)
          loadRows stmt ref
        else pure ()

-- | Parse an exercise name back to its constructor.
nameToExercise :: Text -> Maybe Exercise
nameToExercise t = case filter (\ex -> exerciseName ex == t) allExercises of
  [ex] -> Just ex
  _    -> Nothing
