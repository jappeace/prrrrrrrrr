{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ImportQualifiedPost #-}
module Main where

import Control.Exception (toException)
import Test.Tasty
import Test.Tasty.HUnit

import Data.Map.Strict qualified as Map
import Data.IORef (readIORef, writeIORef)
import Data.Text (Text, unpack)
import Data.Text.Encoding qualified as TE
import Data.Time (addUTCTime, getCurrentTime)
import GymTracker.AppState (AppState(..), Screen(..), newAppState)
import GymTracker.Model
  ( Exercise(..)
  , ExerciseCategory(..)
  , allExercises
  , allCategories
  , categoryName
  , exerciseCategory
  , exerciseName
  , parseExercise
  )
import GymTracker.Storage
  ( withDatabase, initDB, loadRecords, saveRecord, loadExerciseHistory
  , getLastSyncTime, setLastSyncTime, getHistorySince, mergeRecord, mergeHistoryEntry
  , deleteRecordsByExercise, deleteSyncMeta
  , queryHistoryByExerciseAndTime, insertHistory
  )
import GymTracker.Views (AppActions, exerciseListView, enterPRView, appRootView, createAppActions, calculatePercentage, confettiOverlay)
import Hatter.Widget (AnimatedConfig(..), Easing(..), TextAlignment(..), TextConfig(..), Widget(..), WidgetStyle(..))
import Hatter (newActionState, runActionM)

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Sequence qualified as Seq
import GymTracker.ServantNative
  ( NativeClientM
  , runNativeClientM
  , mkNativeClientEnv
  , toHttpMethod
  , toHttpRequest
  , fromHttpResponse
  , fromHttpError
  )
import Hatter
  ( MobileApp(..)
  , defaultMobileContext
  )
import Hatter.AppContext
  ( AppContext(..)
  , newAppContext
  , freeAppContext
  , derefAppContext
  )
import Hatter.Http
  ( HttpMethod(..)
  , HttpRequest(..)
  , HttpResponse(..)
  , HttpError(..)
  , HttpState
  )
import Network.HTTP.Types (statusCode)
import Servant.Client.Core
  ( BaseUrl(..)
  , Scheme(..)
  , ClientError(..)
  , ResponseF(..)
  , RunClient(..)
  )
import Servant.Client.Core.Request (RequestF(..), defaultRequest)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "prrrrrrrrr"
  [ modelTests
  , sequentialTestGroup "Database" AllFinish [storageTests, syncDbTests]
  , viewTests
  , percentageTests
  , confettiTests
  , parseTests
  , syncPureTests
  , servantNativeTests
  ]

modelTests :: TestTree
modelTests = testGroup "Model"
  [ testCase "allExercises has 12 entries" $
      length allExercises @?= 12

  , testCase "exerciseName is unique for each exercise" $
      let names = map exerciseName allExercises
      in length names @?= length (nub names)

  , testCase "allExercises covers Enum range" $
      allExercises @?= [Snatch .. SquatJerk]

  , testCase "all exercises are assigned to exactly one category" $
      let exercisesPerCategory = map (\cat -> length (filter (\ex -> exerciseCategory ex == cat) allExercises)) allCategories
      in sum exercisesPerCategory @?= length allExercises

  , testCase "Snatch and PowerSnatch are in Snatches" $ do
      exerciseCategory Snatch      @?= Snatches
      exerciseCategory PowerSnatch @?= Snatches

  , testCase "Clean, PowerClean, CleanAndJerk are in Cleans" $ do
      exerciseCategory Clean       @?= Cleans
      exerciseCategory PowerClean  @?= Cleans
      exerciseCategory CleanAndJerk @?= Cleans

  , testCase "PushPress, PushJerk, SquatJerk are in JerksAndPresses" $ do
      exerciseCategory PushPress @?= JerksAndPresses
      exerciseCategory PushJerk  @?= JerksAndPresses
      exerciseCategory SquatJerk @?= JerksAndPresses

  , testCase "FrontSquat, BackSquat, OverheadSquat are in Squats" $ do
      exerciseCategory FrontSquat    @?= Squats
      exerciseCategory BackSquat     @?= Squats
      exerciseCategory OverheadSquat @?= Squats

  , testCase "Deadlift is in Pulls" $
      exerciseCategory Deadlift @?= Pulls
  ]
  where
    nub :: Eq a => [a] -> [a]
    nub [] = []
    nub (x:xs) = x : nub (filter (/= x) xs)

-- | Storage tests run sequentially — SQLite is compiled with
-- SQLITE_THREADSAFE=0, so concurrent access to the same file fails.
storageTests :: TestTree
storageTests = sequentialTestGroup "Storage" AllFinish
  [ testCase "saveRecord then loadRecords roundtrip" $ do
      records <- withDatabase $ \conn -> do
        initDB conn
        saveRecord conn Snatch 80.0 Nothing
        saveRecord conn Deadlift 150.5 Nothing
        loadRecords conn
      Map.lookup Snatch records @?= Just 80.0
      Map.lookup Deadlift records @?= Just 150.5

  , testCase "saveRecord overwrites previous value" $ do
      records <- withDatabase $ \conn -> do
        initDB conn
        saveRecord conn BackSquat 100.0 Nothing
        saveRecord conn BackSquat 110.0 Nothing
        loadRecords conn
      Map.lookup BackSquat records @?= Just 110.0

  , testCase "loadExerciseHistory returns entry after saveRecord" $ do
      history <- withDatabase $ \conn -> do
        initDB conn
        saveRecord conn FrontSquat 90.0 Nothing
        loadExerciseHistory conn FrontSquat
      case history of
        [] -> assertFailure "expected at least one history entry"
        ((weight, _timestamp, _notes) : _) -> weight @?= 90.0

  , testCase "multiple saveRecord calls accumulate in history newest first" $ do
      weights <- withDatabase $ \conn -> do
        initDB conn
        saveRecord conn PushPress 60.0 Nothing
        saveRecord conn PushPress 65.0 Nothing
        saveRecord conn PushPress 70.0 Nothing
        history <- loadExerciseHistory conn PushPress
        pure (map (\(w, _, _) -> w) history)
      -- newest first: 70, 65, 60 (plus any from prior test runs)
      take 3 weights @?= [70.0, 65.0, 60.0]

  , testCase "saveRecord with notes roundtrips through loadExerciseHistory" $ do
      history <- withDatabase $ \conn -> do
        initDB conn
        saveRecord conn CleanAndJerk 95.0 (Just "belt used")
        loadExerciseHistory conn CleanAndJerk
      case history of
        [] -> assertFailure "expected at least one history entry"
        ((weight, _timestamp, notes) : _) -> do
          weight @?= 95.0
          notes @?= Just "belt used"
  ]

-- | Create a test AppState + AppActions pair.
mkTestActions :: IO (AppState, AppActions)
mkTestActions = do
  st <- newAppState Map.empty
  actionSt <- newActionState
  actions <- runActionM actionSt (createAppActions st)
  pure (st, actions)

viewTests :: TestTree
viewTests = testGroup "Views"
  [ testCase "exerciseListView returns ScrollView wrapping Column with correct child count" $ do
      (st, actions) <- mkTestActions
      widget <- exerciseListView actions st
      case widget of
        ScrollView [Column children] ->
          -- 1 title + 1 percentage input + 5 category headers + 12 exercise buttons = 19
          length children @?= 19
        ScrollView _ -> assertFailure "expected ScrollView with single Column child"
        _            -> assertFailure "expected ScrollView"

  , testCase "exerciseListView third Column child is centered Text Snatches category header" $ do
      (st, actions) <- mkTestActions
      widget <- exerciseListView actions st
      case widget of
        ScrollView [Column (_ : _ : thirdChild : _)] ->
          case thirdChild of
            Styled style (Text config) -> do
              tcLabel config @?= categoryName Snatches
              wsTextAlign style @?= Just AlignCenter
            Styled _ _  -> assertFailure "expected Styled wrapping Text"
            Text _      -> assertFailure "expected Styled Text, got bare Text"
            _           -> assertFailure "expected Styled Text for category header"
        ScrollView _ -> assertFailure "expected at least 3 children in Column"
        _            -> assertFailure "expected ScrollView"

  , testCase "enterPRView returns Column with input, buttons, and history section" $ do
      (st, actions) <- mkTestActions
      widget <- enterPRView actions st Snatch
      case widget of
        Column children ->
          -- "Set PR:" label + exercise name + weight TextInput + notes TextInput + Row of buttons + Column history = 6
          length children @?= 6
        Text _          -> assertFailure "expected Column, got Text"
        Button _        -> assertFailure "expected Column, got Button"
        TextInput _     -> assertFailure "expected Column, got TextInput"
        Row _           -> assertFailure "expected Column, got Row"
        ScrollView _    -> assertFailure "expected Column, got ScrollView"
        Image _         -> assertFailure "expected Column, got Image"
        WebView _       -> assertFailure "expected Column, got WebView"
        MapView _       -> assertFailure "expected Column, got MapView"
        Styled _ _      -> assertFailure "expected Column, got Styled"
        Animated _ _    -> assertFailure "expected Column, got Animated"

  , testCase "enterPRView with history shows entries in 6th Column child" $ do
      (st, actions) <- mkTestActions
      writeIORef (stHistory st) [(100.0, "2026-01-01 12:00:00", Nothing), (90.0, "2025-12-01 10:00:00", Nothing)]
      widget <- enterPRView actions st Snatch
      case widget of
        Column [_, _, _, _, _, Column historyWidgets] ->
          length historyWidgets @?= 2
        Column _ -> assertFailure "expected 6 children with history Column as 6th"
        _        -> assertFailure "expected Column"

  , testCase "appRootView dispatches to correct screen" $ do
      (st, actions) <- mkTestActions
      widget <- appRootView actions st
      case widget of
        Styled _ (ScrollView [Column (Styled _ (Text config) : _)]) ->
          tcLabel config @?= "PRRRRRRRRR"
        Styled _ (ScrollView _) -> assertFailure "expected ScrollView with Column as first child"
        Styled _ _              -> assertFailure "expected Styled wrapping ScrollView"
        _                       -> assertFailure "expected Styled"

  , testCase "screen navigation: list -> enter PR -> back" $ do
      st <- newAppState Map.empty
      screen0 <- readIORef (stScreen st)
      screen0 @?= ExerciseList
      writeIORef (stScreen st) (EnterPR Snatch)
      screen1 <- readIORef (stScreen st)
      screen1 @?= EnterPR Snatch
      writeIORef (stScreen st) ExerciseList
      screen2 <- readIORef (stScreen st)
      screen2 @?= ExerciseList
  ]

percentageTests :: TestTree
percentageTests = testGroup "Percentage calculator"
  [ testCase "calculatePercentage 80kg at 80% = 64.0" $
      calculatePercentage 80.0 80 @?= 64.0

  , testCase "calculatePercentage 100kg at 50% = 50.0" $
      calculatePercentage 100.0 50 @?= 50.0

  , testCase "calculatePercentage 100kg at 100% = 100.0" $
      calculatePercentage 100.0 100 @?= 100.0

  , testCase "exerciseListView adds percentage rows when percentage is set" $ do
      st <- newAppState (Map.fromList [(Snatch, 80.0), (Deadlift, 150.0)])
      writeIORef (stPercentage st) 80
      actionSt <- newActionState
      actions <- runActionM actionSt (createAppActions st)
      widget <- exerciseListView actions st
      case widget of
        ScrollView [Column children] ->
          -- 1 title + 1 percentage input + 5 category headers
          -- + 12 exercise buttons + 2 percentage text rows (Snatch + Deadlift have PRs)
          -- = 21
          length children @?= 21
        ScrollView _ -> assertFailure "expected ScrollView with single Column child"
        _            -> assertFailure "expected ScrollView"

  , testCase "exerciseListView percentage row shows correct calculated weight" $ do
      st <- newAppState (Map.fromList [(Snatch, 80.0)])
      writeIORef (stPercentage st) 80
      actionSt <- newActionState
      actions <- runActionM actionSt (createAppActions st)
      widget <- exerciseListView actions st
      case widget of
        ScrollView [Column children] ->
          -- Find the percentage text row after the Snatch button
          -- Layout: title, %input, "Snatches" header, Snatch button, percentage text, ...
          case drop 3 children of  -- skip title, %input, Snatches header
            (_button : Styled _style (Text config) : _) ->
              tcLabel config @?= "64.0 kg @ 80%"
            _ -> assertFailure "expected button followed by percentage text"
        ScrollView _ -> assertFailure "expected ScrollView with single Column child"
        _            -> assertFailure "expected ScrollView"
  ]

confettiTests :: TestTree
confettiTests = testGroup "Confetti"
  [ testCase "enterPRView without confetti has 6 children" $ do
      (st, actions) <- mkTestActions
      widget <- enterPRView actions st Snatch
      case widget of
        Column children -> length children @?= 6
        _               -> assertFailure "expected Column"

  , testCase "enterPRView with confetti has 7 children (overlay + 6 form)" $ do
      (st, actions) <- mkTestActions
      writeIORef (stConfetti st) True
      widget <- enterPRView actions st Snatch
      case widget of
        Column children -> length children @?= 7
        _               -> assertFailure "expected Column"

  , testCase "enterPRView confetti first child is Animated" $ do
      (st, actions) <- mkTestActions
      writeIORef (stConfetti st) True
      widget <- enterPRView actions st Snatch
      case widget of
        Column (Animated config _ : _) -> do
          anDuration config @?= 1200
          anEasing config @?= EaseOut
        Column _ -> assertFailure "expected first child to be Animated"
        _        -> assertFailure "expected Column"

  , testCase "confettiOverlay contains 20 particles in a Column" $ do
      widget <- confettiOverlay
      case widget of
        Animated _ (Column particles) -> length particles @?= 20
        Animated _ _                  -> assertFailure "expected Column inside Animated"
        _                             -> assertFailure "expected Animated"
  ]

-- | Replicate the parseWeight logic from Views for testing.
parseWeightText :: Text -> Maybe Double
parseWeightText t =
  case reads (unpack t) of
    [(w, "")] | w > 0 -> Just w
    _                  -> Nothing

parseTests :: TestTree
parseTests = testGroup "Weight parsing"
  [ testCase "valid positive number parses" $
      parseWeightText "80.5" @?= Just 80.5

  , testCase "integer parses as Double" $
      parseWeightText "100" @?= Just 100.0

  , testCase "empty string does not parse" $
      parseWeightText "" @?= Nothing

  , testCase "non-numeric does not parse" $
      parseWeightText "abc" @?= Nothing

  , testCase "negative number does not parse" $
      parseWeightText "-5" @?= Nothing

  , testCase "zero does not parse" $
      parseWeightText "0" @?= Nothing
  ]

syncPureTests :: TestTree
syncPureTests = testGroup "Sync pure"
  [ testCase "parseExercise roundtrips for all exercises" $
      mapM_ (\ex -> parseExercise (exerciseName ex) @?= Just ex) allExercises

  , testCase "parseExercise rejects unknown text" $ do
      parseExercise "Unknown Lift" @?= Nothing
      parseExercise "" @?= Nothing
  ]

syncDbTests :: TestTree
syncDbTests = sequentialTestGroup "Sync DB" AllFinish
  [ testCase "mergeRecord inserts when no existing record" $ do
      records <- withDatabase $ \conn -> do
        initDB conn
        -- Clear any prior test data
        deleteRecordsByExercise conn Clean
        mergeRecord conn Clean 85.0
        loadRecords conn
      Map.lookup Clean records @?= Just 85.0

  , testCase "mergeRecord updates only if weight is strictly higher" $ do
      (records1, records2, records3) <- withDatabase $ \conn -> do
        initDB conn
        deleteRecordsByExercise conn PowerSnatch
        mergeRecord conn PowerSnatch 60.0
        mergeRecord conn PowerSnatch 55.0  -- lower, should not update
        r1 <- loadRecords conn
        mergeRecord conn PowerSnatch 60.0  -- equal, should not update
        r2 <- loadRecords conn
        mergeRecord conn PowerSnatch 65.0  -- higher, should update
        r3 <- loadRecords conn
        pure (r1, r2, r3)
      Map.lookup PowerSnatch records1 @?= Just 60.0
      Map.lookup PowerSnatch records2 @?= Just 60.0
      Map.lookup PowerSnatch records3 @?= Just 65.0

  , testCase "mergeHistoryEntry deduplicates identical entries" $ do
      duplicateCount <- withDatabase $ \conn -> do
        initDB conn
        now <- getCurrentTime
        mergeHistoryEntry conn Snatch 80.0 now Nothing
        mergeHistoryEntry conn Snatch 80.0 now Nothing  -- duplicate
        matches <- queryHistoryByExerciseAndTime conn Snatch 80.0 now
        pure (length matches)
      duplicateCount @?= 1

  , testCase "mergeHistoryEntry inserts distinct entries" $ do
      matchCount <- withDatabase $ \conn -> do
        initDB conn
        now <- getCurrentTime
        let later = addUTCTime 60 now
        mergeHistoryEntry conn Snatch 80.0 now Nothing
        mergeHistoryEntry conn Snatch 85.0 later Nothing  -- different timestamp and weight
        nowMatches <- queryHistoryByExerciseAndTime conn Snatch 80.0 now
        laterMatches <- queryHistoryByExerciseAndTime conn Snatch 85.0 later
        pure (length nowMatches + length laterMatches)
      matchCount @?= 2

  , testCase "getHistorySince returns only entries after given time" $ do
      ohsEntries <- withDatabase $ \conn -> do
        initDB conn
        now <- getCurrentTime
        let past = addUTCTime (-120) now
            middle = addUTCTime (-60) now
        -- Insert entries at specific times
        insertHistory conn OverheadSquat 70.0 past Nothing
        insertHistory conn OverheadSquat 75.0 now Nothing
        entries <- getHistorySince conn middle
        pure $ filter (\(ex, _, _, _) -> ex == OverheadSquat) entries
      -- Only the entry at 'now' should be returned (past < middle, now > middle)
      length ohsEntries @?= 1
      case ohsEntries of
        [(_, weight, _, _)] -> weight @?= 75.0
        _                   -> assertFailure "expected exactly one OHS entry"

  , testCase "sync_meta roundtrip for last sync time" $ do
      (noSync, retrieved, now) <- withDatabase $ \conn -> do
        initDB conn
        deleteSyncMeta conn "last_sync_time"
        noSync <- getLastSyncTime conn
        now <- getCurrentTime
        setLastSyncTime conn now
        retrieved <- getLastSyncTime conn
        pure (noSync, retrieved, now)
      noSync @?= Nothing
      retrieved @?= Just now
  ]

-- | Tests for GymTracker.ServantNative conversion helpers and client monad.
servantNativeTests :: TestTree
servantNativeTests = testGroup "ServantNative"
  [ toHttpMethodTests
  , toHttpRequestTests
  , fromHttpResponseTests
  , fromHttpErrorTests
  , runClientTests
  ]

testBaseUrl :: BaseUrl
testBaseUrl = BaseUrl Http "localhost" 8080 ""

toHttpMethodTests :: TestTree
toHttpMethodTests = testGroup "toHttpMethod"
  [ testCase "GET maps to HttpGet" $
      toHttpMethod "GET" @?= Right HttpGet
  , testCase "POST maps to HttpPost" $
      toHttpMethod "POST" @?= Right HttpPost
  , testCase "PUT maps to HttpPut" $
      toHttpMethod "PUT" @?= Right HttpPut
  , testCase "DELETE maps to HttpDelete" $
      toHttpMethod "DELETE" @?= Right HttpDelete
  , testCase "unknown method returns Left" $ do
      let result = toHttpMethod "PATCH"
      case result of
        Left _ -> pure ()
        Right _ -> assertFailure "expected Left for unsupported method"
  ]

toHttpRequestTests :: TestTree
toHttpRequestTests = testGroup "toHttpRequest"
  [ testCase "builds correct URL from BaseUrl and path" $ do
      let request = defaultRequest { requestMethod = "GET", requestPath = "/api/users" }
      case toHttpRequest testBaseUrl request of
        Left errorMessage -> assertFailure ("toHttpRequest failed: " ++ show errorMessage)
        Right httpReq -> do
          let urlBytes = TE.encodeUtf8 (hrUrl httpReq)
          assertBool "URL contains base" ("http://localhost:8080" `BS.isPrefixOf` urlBytes)
          assertBool "URL contains path" ("/api/users" `BS.isInfixOf` urlBytes)
          hrMethod httpReq @?= HttpGet

  , testCase "builds correct URL with query string" $ do
      let request = defaultRequest
            { requestMethod = "GET"
            , requestPath = "/search"
            , requestQueryString = Seq.fromList [("q", Just "hello")]
            }
      case toHttpRequest testBaseUrl request of
        Left errorMessage -> assertFailure ("toHttpRequest failed: " ++ show errorMessage)
        Right httpReq ->
          assertBool "URL contains query" ("?q=hello" `BS.isInfixOf` TE.encodeUtf8 (hrUrl httpReq))

  , testCase "rejects unsupported method" $ do
      let request = defaultRequest { requestMethod = "PATCH" }
      case toHttpRequest testBaseUrl request of
        Left _ -> pure ()
        Right _ -> assertFailure "expected Left for PATCH"
  ]

fromHttpResponseTests :: TestTree
fromHttpResponseTests = testGroup "fromHttpResponse"
  [ testCase "converts status code 200" $ do
      let httpResp = HttpResponse 200 [] BS.empty
          response = fromHttpResponse httpResp
      statusCode (responseStatusCode response) @?= 200

  , testCase "converts status code 404" $ do
      let httpResp = HttpResponse 404 [] BS.empty
          response = fromHttpResponse httpResp
      statusCode (responseStatusCode response) @?= 404

  , testCase "converts response headers" $ do
      let httpResp = HttpResponse 200 [("Content-Type", "application/json")] BS.empty
          response = fromHttpResponse httpResp
      Seq.length (responseHeaders response) @?= 1

  , testCase "converts response body" $ do
      let httpResp = HttpResponse 200 [] "hello"
          response = fromHttpResponse httpResp
      responseBody response @?= LBS.fromStrict "hello"
  ]

fromHttpErrorTests :: TestTree
fromHttpErrorTests = testGroup "fromHttpError"
  [ testCase "HttpNetworkError becomes ConnectionError" $ do
      let clientError = fromHttpError (HttpNetworkError "connection refused")
      case clientError of
        ConnectionError _ -> pure ()
        FailureResponse _ _ -> assertFailure "expected ConnectionError"
        DecodeFailure _ _ -> assertFailure "expected ConnectionError"
        UnsupportedContentType _ _ -> assertFailure "expected ConnectionError"
        InvalidContentTypeHeader _ -> assertFailure "expected ConnectionError"

  , testCase "HttpTimeout becomes ConnectionError" $ do
      let clientError = fromHttpError HttpTimeout
      case clientError of
        ConnectionError _ -> pure ()
        FailureResponse _ _ -> assertFailure "expected ConnectionError"
        DecodeFailure _ _ -> assertFailure "expected ConnectionError"
        UnsupportedContentType _ _ -> assertFailure "expected ConnectionError"
        InvalidContentTypeHeader _ -> assertFailure "expected ConnectionError"
  ]

-- | Tests that exercise the actual 'RunClient' instance via the desktop HTTP stub.
-- The desktop stub always returns 200 OK with empty body.
runClientTests :: TestTree
runClientTests = testGroup "runNativeClientM"
  [ testCase "simple GET via desktop stub returns 200" $
      withTestAppContext $ \httpState -> do
        let env = mkNativeClientEnv httpState testBaseUrl
            request = defaultRequest { requestMethod = "GET", requestPath = "/test" }
        result <- runNativeClientM (runRequestAcceptStatus Nothing request) env
        case result of
          Right response -> statusCode (responseStatusCode response) @?= 200
          Left clientError -> assertFailure ("expected 200 OK, got: " ++ show clientError)

  , testCase "throwClientError propagates" $
      withTestAppContext $ \httpState -> do
        let env = mkNativeClientEnv httpState testBaseUrl
            expectedError :: ClientError
            expectedError = ConnectionError (toException (userError "test error"))
        result <- runNativeClientM (throwClientError expectedError :: NativeClientM ()) env
        case result of
          Left (ConnectionError _) -> pure ()
          Left _ -> assertFailure "expected ConnectionError"
          Right _ -> assertFailure "expected Left"
  ]

-- | Create a temporary 'AppContext' with a properly wired 'HttpState',
-- run the given action, then free the context.
withTestAppContext :: (HttpState -> IO a) -> IO a
withTestAppContext action = do
  actionSt <- newActionState
  let dummyApp = MobileApp
        { maContext = defaultMobileContext
        , maView = \_userState -> pure (Text (TextConfig "" Nothing))
        , maActionState = actionSt
        }
  ctxPtr <- newAppContext dummyApp
  appCtx <- derefAppContext ctxPtr
  result <- action (acHttpState appCtx)
  freeAppContext ctxPtr
  pure result
