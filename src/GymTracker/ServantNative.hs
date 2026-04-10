{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ImportQualifiedPost #-}
-- | Servant client backend using native HTTP bindings from haskell-mobile.
--
-- Routes servant requests through 'HaskellMobile.Http.performRequest'
-- instead of @http-client@\/@http-client-tls@, avoiding ~90 MB of
-- TLS/crypto dependencies in the Android .so.
module GymTracker.ServantNative
  ( NativeClientM(..)
  , NativeClientEnv(..)
  , runNativeClientM
  , mkNativeClientEnv
  -- * Conversion helpers (exported for testing)
  , toHttpMethod
  , toHttpRequest
  , fromHttpResponse
  , fromHttpError
  )
where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, toException)
import Control.Monad.Except (ExceptT, MonadError, runExceptT, throwError)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (ReaderT, MonadReader, runReaderT, ask)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LBS
import Data.CaseInsensitive qualified as CI
import Data.Foldable (toList)
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import HaskellMobile.Http
  ( HttpMethod(..)
  , HttpRequest(..)
  , HttpResponse(..)
  , HttpError(..)
  , HttpState
  , performRequest
  )
import Network.HTTP.Media (MediaType, renderHeader)
import Network.HTTP.Types (mkStatus, statusCode, renderQuery, Header)
import Network.HTTP.Types.Version (http11)
import Servant.Client.Core
  ( BaseUrl
  , ClientError(..)
  , RequestBody(..)
  , ResponseF(..)
  , RunClient(..)
  , showBaseUrl
  )
import Servant.Client.Core.Request (Request, RequestF(..))

-- | Client monad that routes servant requests through native HTTP bindings.
newtype NativeClientM a = NativeClientM
  { unNativeClientM :: ReaderT NativeClientEnv (ExceptT ClientError IO) a }
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadError ClientError, MonadReader NativeClientEnv)

-- | Environment for 'NativeClientM'.
data NativeClientEnv = NativeClientEnv
  { nceHttpState :: HttpState
  , nceBaseUrl   :: BaseUrl
  }

-- | Run a 'NativeClientM' action.
runNativeClientM :: NativeClientM a -> NativeClientEnv -> IO (Either ClientError a)
runNativeClientM action env =
  runExceptT (runReaderT (unNativeClientM action) env)

-- | Construct a 'NativeClientEnv'.
mkNativeClientEnv :: HttpState -> BaseUrl -> NativeClientEnv
mkNativeClientEnv = NativeClientEnv

instance RunClient NativeClientM where
  runRequestAcceptStatus acceptStatuses servantReq = do
    env <- ask
    let baseUrl = nceBaseUrl env
    case toHttpRequest baseUrl servantReq of
      Left errorMessage ->
        throwError (ConnectionError (toSomeException errorMessage))
      Right httpReq -> do
        result <- liftIO $ do
          mvar <- newEmptyMVar
          performRequest (nceHttpState env) httpReq (putMVar mvar)
          takeMVar mvar
        case result of
          Left httpError -> throwError (fromHttpError httpError)
          Right httpResp -> do
            let response = fromHttpResponse httpResp
                code = statusCode (responseStatusCode response)
                isAcceptable = case acceptStatuses of
                      Nothing -> code >= 200 && code < 300
                      Just statuses -> responseStatusCode response `elem` statuses
            if isAcceptable
              then pure response
              else throwError (FailureResponse (stripRequest baseUrl servantReq) response)

  throwClientError = throwError

-- | Strip a servant 'Request' to the form used in 'FailureResponse'.
stripRequest :: BaseUrl -> Request -> RequestF () (BaseUrl, ByteString)
stripRequest baseUrl servantReq = Request
  { requestPath        = (baseUrl, renderedPath)
  , requestQueryString = requestQueryString servantReq
  , requestBody        = Nothing
  , requestAccept      = requestAccept servantReq
  , requestHeaders     = requestHeaders servantReq
  , requestHttpVersion = http11
  , requestMethod      = requestMethod servantReq
  }
  where
    renderedPath :: ByteString
    renderedPath = LBS.toStrict (Builder.toLazyByteString (requestPath servantReq))

-- | Convert servant HTTP method 'ByteString' to 'HttpMethod'.
toHttpMethod :: ByteString -> Either Text HttpMethod
toHttpMethod "GET"    = Right HttpGet
toHttpMethod "POST"   = Right HttpPost
toHttpMethod "PUT"    = Right HttpPut
toHttpMethod "DELETE" = Right HttpDelete
toHttpMethod other    = Left ("unsupported HTTP method: " <> TE.decodeUtf8 other)

-- | Convert a servant 'Request' to a native 'HttpRequest'.
toHttpRequest :: BaseUrl -> Request -> Either Text HttpRequest
toHttpRequest baseUrl servantReq = do
  method <- toHttpMethod (requestMethod servantReq)
  let pathBytes = LBS.toStrict (Builder.toLazyByteString (requestPath servantReq))
      queryItems = toList (requestQueryString servantReq)
      queryString = renderQuery True queryItems
      url = Text.pack (showBaseUrl baseUrl)
         <> TE.decodeUtf8 pathBytes
         <> TE.decodeUtf8 queryString
      servantHeaders = toList (requestHeaders servantReq)
      acceptHeaders = case toList (requestAccept servantReq) of
        [] -> []
        mediaTypes -> [("Accept", Text.intercalate ", " (map renderMediaType mediaTypes))]
      contentTypeHeaders = case requestBody servantReq of
        Just (_, mediaType) -> [("Content-Type", renderMediaType mediaType)]
        Nothing -> []
      allHeaders = map headerToTextPair servantHeaders
              ++ acceptHeaders
              ++ contentTypeHeaders
      body = case requestBody servantReq of
        Just (RequestBodyBS bs, _)      -> bs
        Just (RequestBodyLBS lbs, _)    -> LBS.toStrict lbs
        Just (RequestBodySource _, _)   -> BS.empty
        Nothing                         -> BS.empty
  Right HttpRequest
    { hrMethod  = method
    , hrUrl     = url
    , hrHeaders = allHeaders
    , hrBody    = body
    }

-- | Convert an 'HttpResponse' to a servant 'Response'.
fromHttpResponse :: HttpResponse -> ResponseF LBS.ByteString
fromHttpResponse httpResp = Response
  { responseStatusCode  = mkStatus (hrStatusCode httpResp) ""
  , responseHeaders     = Seq.fromList (map textPairToHeader (hrRespHeaders httpResp))
  , responseHttpVersion = http11
  , responseBody        = LBS.fromStrict (hrRespBody httpResp)
  }

-- | Convert an 'HttpError' to a servant 'ClientError'.
fromHttpError :: HttpError -> ClientError
fromHttpError (HttpNetworkError message) =
  ConnectionError (toSomeException message)
fromHttpError HttpTimeout =
  ConnectionError (toSomeException ("HTTP request timed out" :: Text))

-- | Wrap a 'Text' message into a 'SomeException' via 'userError'.
toSomeException :: Text -> SomeException
toSomeException = toException . userError . Text.unpack

-- | Convert a servant 'Header' to a @(Text, Text)@ pair.
headerToTextPair :: Header -> (Text, Text)
headerToTextPair (name, value) =
  (TE.decodeUtf8 (CI.original name), TE.decodeUtf8 value)

-- | Convert a @(Text, Text)@ pair to a servant 'Header'.
textPairToHeader :: (Text, Text) -> Header
textPairToHeader (name, value) =
  (CI.mk (TE.encodeUtf8 name), TE.encodeUtf8 value)

-- | Render a 'MediaType' as 'Text' (e.g. @\"application/json\"@).
renderMediaType :: MediaType -> Text
renderMediaType = TE.decodeUtf8 . renderHeader
