{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE OverloadedStrings    #-}

-- | Data types for curl-runnings tests

module Testing.CurlRunnings.Types
  ( AssertionFailure(..)
  , CaseResult(..)
  , CurlSuite(..)
  , CurlCase(..)
  , Header(..)
  , HeaderMatcher(..)
  , Headers(..)
  , HttpMethod(..)
  , JsonMatcher(..)
  , JsonSubExpr(..)
  , PartialHeaderMatcher(..)
  , StatusCodeMatcher(..)

  , isFailing
  , isPassing

  ) where

import           Data.Aeson
import           Data.Aeson.Encode.Pretty
import           Data.Aeson.Types
import qualified Data.ByteString.Lazy.Char8    as B8
import           Data.Either
import qualified Data.HashMap.Strict           as H
import           Data.List
import           Data.Maybe
import qualified Data.Text                     as T
import qualified Data.Vector                   as V
import           GHC.Generics
import           Testing.CurlRunnings.Internal
import           Text.Printf

-- | A basic enum for supported HTTP verbs
data HttpMethod
  = GET
  | POST
  | PUT
  | PATCH
  | DELETE
  deriving (Show, Generic)

instance FromJSON HttpMethod

instance ToJSON HttpMethod

-- | A predicate to apply to the json body from the response
data JsonMatcher
  -- | Performs `==`
  = Exactly Value
  -- | A list of matchers to make assertions about some subset of the response.
  | Contains [JsonSubExpr]
  deriving (Show, Generic)

instance ToJSON JsonMatcher

instance FromJSON JsonMatcher where
  parseJSON (Object v)
    | isJust $ H.lookup "exactly" v = Exactly <$> v .: "exactly"
    | isJust $ H.lookup "contains" v = Contains <$> v .: "contains"
  parseJSON invalid = typeMismatch "JsonMatcher" invalid

-- | A representation of a single header
data Header =
  Header T.Text
         T.Text
  deriving (Show, Generic)

instance ToJSON Header

-- | Simple container for a list of headers, useful for a vehicle for defining a
-- fromJSON
data Headers =
  HeaderSet [Header]
  deriving (Show, Generic)

instance ToJSON Headers

-- | Specify a key, value, or both to match against in the returned headers of a
-- response.
data PartialHeaderMatcher =
  PartialHeaderMatcher (Maybe T.Text)
                       (Maybe T.Text)
  deriving (Show, Generic)
instance ToJSON PartialHeaderMatcher

-- | Collection of matchers to run against a single curl response
data HeaderMatcher =
  HeaderMatcher [PartialHeaderMatcher]
  deriving (Show, Generic)

instance ToJSON HeaderMatcher

parseHeader :: T.Text -> Either T.Text Header
parseHeader str =
  case map T.strip $ T.splitOn ":" str of
    [key, val] -> Right $ Header key val
    anythingElse -> Left . T.pack $ "bad header found: " ++ (show anythingElse)

parseHeaders :: T.Text -> Either T.Text Headers
parseHeaders str =
  let _headers = filter (/= "") $ T.splitOn ";" str
      parses = map parseHeader _headers
  in case find isLeft parses of
       Just (Left failure) -> Left failure
       _ ->
         Right . HeaderSet $
         map
           (fromRight $
            error
              "Internal error parsing headers, this is a bug in curl runnings :(")
           parses

instance FromJSON Headers where
  parseJSON a@(String v) =
    case parseHeaders v of
      Right h      -> return h
      Left failure -> typeMismatch ("Header failure: " ++ T.unpack failure) a
  parseJSON invalid = typeMismatch "Header" invalid

instance FromJSON HeaderMatcher where
  parseJSON o@(String v) =
    either
      (\s -> typeMismatch ("HeaderMatcher: " ++ T.unpack s) o)
      (\(HeaderSet parsed) ->
         return . HeaderMatcher $
         map
           (\(Header key val) -> PartialHeaderMatcher (Just key) (Just val))
           parsed)
      (parseHeaders v)
  parseJSON (Object v) = do
    partial <- PartialHeaderMatcher <$> v .:? "key" <*> v .:? "value"
    return $ HeaderMatcher [partial]
  parseJSON (Array v) = mconcat . V.toList $ V.map parseJSON v
  parseJSON invalid = typeMismatch "HeaderMatcher" invalid

-- | A matcher for a subvalue of a json payload
data JsonSubExpr
  -- | Assert some value anywhere in the json has a value equal to a given
  --  value. The motivation for this field is largely for checking contents of a
  --  top level array. It's also useful if you don't know the key ahead of time.
  = ValueMatch Value
  -- | Assert the key value pair can be found somewhere the json.
  | KeyValueMatch { matchKey   :: T.Text
                  , matchValue :: Value }
  deriving (Show, Generic)

instance FromJSON JsonSubExpr where
  parseJSON (Object v)
    | isJust $ H.lookup "keyValueMatch" v =
      let toParse = fromJust $ H.lookup "keyValueMatch" v
      in case toParse of
           Object o -> KeyValueMatch <$> o .: "key" <*> o .: "value"
           _        -> typeMismatch "JsonSubExpr" toParse
    | isJust $ H.lookup "valueMatch" v = ValueMatch <$> v .: "valueMatch"
  parseJSON invalid = typeMismatch "JsonSubExpr" invalid
instance ToJSON JsonSubExpr

-- | Check the status code of a response. You can specify one or many valid codes.
data StatusCodeMatcher
  = ExactCode Int
  | AnyCodeIn [Int]
  deriving (Show, Generic)

instance ToJSON StatusCodeMatcher

instance FromJSON StatusCodeMatcher where
  parseJSON obj@(Number _) = ExactCode <$> parseJSON obj
  parseJSON obj@(Array _)  = AnyCodeIn <$> parseJSON obj
  parseJSON invalid        = typeMismatch "StatusCodeMatcher" invalid

-- | A single curl test case, the basic foundation of a curl-runnings test.
data CurlCase = CurlCase
  { name          :: String -- ^ The name of the test case
  , url           :: String -- ^ The target url to test
  , requestMethod :: HttpMethod -- ^ Verb to use for the request
  , requestData   :: Maybe Value -- ^ Payload to send with the request, if any
  , headers       :: Maybe Headers -- ^ Headers to send with the request, if any
  , expectData    :: Maybe JsonMatcher -- ^ The assertions to make on the response payload, if any
  , expectStatus  :: StatusCodeMatcher -- ^ Assertion about the status code returned by the target
  , expectHeaders :: Maybe HeaderMatcher -- ^ Assertions to make about the response headers, if any
  } deriving (Show, Generic)

instance FromJSON CurlCase

instance ToJSON CurlCase

-- | Represents the different type of test failures we can have. A single test case
-- | might return many assertion failures.
data AssertionFailure
  -- | The json we got back was wrong. We include this redundant field (it's
  -- included in the CurlCase field above) in order to enforce at the type
  -- level that we have to be expecting some data in order to have this type of
  -- failure.
  = DataFailure CurlCase
                JsonMatcher
                (Maybe Value)
  -- | The status code we got back was wrong
  | StatusFailure CurlCase
                  Int
  -- | The headers we got back were wrong
  | HeaderFailure CurlCase
                  HeaderMatcher
                  Headers
  -- | Something else
  | UnexpectedFailure

instance Show AssertionFailure where
  show (StatusFailure c receivedCode) =
    case expectStatus c of
      ExactCode code ->
        printf
          "Incorrect status code from %s. Expected: %s. Actual: %s"
          (url c)
          (show code)
          (show receivedCode)
      AnyCodeIn codes ->
        printf
          "Incorrect status code from %s. Expected one of: %s. Actual: %s"
          (url c)
          (show codes)
          (show receivedCode)
  show (DataFailure curlCase expected receivedVal) =
    case expected of
      Exactly expectedVal ->
        printf
          "JSON response from %s didn't match spec. Expected: %s. Actual: %s"
          (url curlCase)
          (B8.unpack (encodePretty expectedVal))
          (B8.unpack (encodePretty receivedVal))
      (Contains expectedVals) ->
        printf
          "JSON response from %s didn't contain the matcher. Expected: %s to be each be subvalues in: %s"
          (url curlCase)
          (B8.unpack (encodePretty expectedVals))
          (B8.unpack (encodePretty receivedVal))
  show (HeaderFailure curlCase expected receivedHeaders) =
    printf
      "Headers from %s didn't contain expected headers. Expected headers: %s. Recieved headers: %s"
      (url curlCase)
      (show expected)
      (show receivedHeaders)
  show UnexpectedFailure = "Unexpected Error D:"

-- | A type representing the result of a single curl, and all associated
-- assertions
data CaseResult
  = CasePass CurlCase
  | CaseFail CurlCase
             [AssertionFailure]

instance Show CaseResult where
  show (CasePass c) = makeGreen "[PASS] " ++ name c
  show (CaseFail c failures) =
    makeRed "[FAIL] " ++
    name c ++
    "\n" ++
    concatMap ((\s -> "\nAssertion failed: " ++ s) . (++ "\n") . show) failures

-- | A wrapper type around a set of test cases. This is the top level spec type
-- that we parse a test spec file into
newtype CurlSuite =
  CurlSuite [CurlCase]
  deriving (Show, Generic)

instance FromJSON CurlSuite

instance ToJSON CurlSuite

-- | Simple predicate that checks if the result is passing
isPassing :: CaseResult -> Bool
isPassing (CasePass _)   = True
isPassing (CaseFail _ _) = False

-- | Simple predicate that checks if the result is failing
isFailing :: CaseResult -> Bool
isFailing (CasePass _)   = False
isFailing (CaseFail _ _) = True
