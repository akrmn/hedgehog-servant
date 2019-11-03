module Hedgehog.Servant
  ( GList(..)
  , HasGen(..)
  , GenRequest(..)
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Internal as BS (c2w)
import qualified Data.CaseInsensitive as CI
import           Data.Proxy (Proxy(..))
import           Data.String.Conversions (ConvertibleStrings, cs)
import           GHC.TypeLits (KnownSymbol, symbolVal)
import           Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import           Network.HTTP.Media (renderHeader)
import           Network.HTTP.Client (Request(..), RequestBody(..))
import           Network.HTTP.Client (defaultRequest)
import           Network.HTTP.Types (HeaderName)
import           Servant.API (ToHttpApiData(..))
import           Servant.API (Capture', CaptureAll, Header', Description, Summary)
import           Servant.API (ReqBody', Verb, ReflectMethod)
import           Servant.API ((:>), (:<|>))
import           Servant.API (reflectMethod)
import           Servant.API.ContentTypes (AllMimeRender(..))
import           Servant.Client (BaseUrl(..), Scheme(..))

-- | Data structure used in order to specify generators for API
--
-- Example usage:
--
-- @
-- type Api = "cats" :> ReqBody '[JSON] Cat :> Post '[JSON] ()
--
-- catGen :: Gen Cat
-- catGen = _
--
-- genApi :: Gen (BaseUrl -> Request)
-- genApi = genRequest (Proxy @Api) (catGen :*: GNil)
-- @
data GList (a :: [*]) where
  GNil :: GList '[]
  (:*:) :: Gen x -> GList xs -> GList (Gen x ': xs)

infixr 6 :*:

-- | Simple getter from a GList of possible generators
class HasGen (g :: *) (gens :: [*]) where
  getGen :: GList gens -> Gen g

instance {-# OVERLAPPING #-} HasGen h (Gen h ': rest) where
  getGen (ha :*: _) = ha

instance {-# OVERLAPPABLE #-} (HasGen h rest) => HasGen h (first ': rest) where
  getGen (_ :*: hs) = getGen hs

-- | Type class used to generate requests from a 'GList gens' for API 'api'
class GenRequest (api :: *) (gens :: [*]) where
  genRequest :: Proxy api -> GList gens -> Gen (BaseUrl -> Request)

-- | Instance for composite APIs
instance
  ( GenRequest a reqs
  , GenRequest b reqs
  ) => GenRequest (a :<|> b) reqs where
  genRequest _ gens =
    Gen.choice
      [ genRequest (Proxy @a) gens
      , genRequest (Proxy @b) gens
      ]

-- | Instance for description
instance
  ( GenRequest api reqs
  ) => GenRequest (Description d :> api) reqs where
  genRequest _ = genRequest (Proxy @api)

-- | Instance for summary
instance
  ( GenRequest api reqs
  ) => GenRequest (Summary s :> api) reqs where
  genRequest _ = genRequest (Proxy @api)

-- | Instance for path part of API
instance
  ( KnownSymbol path
  , GenRequest api reqs
  ) => GenRequest (path :> api) reqs where
  genRequest _ gens = do
    makeRequest <- genRequest (Proxy @api) gens
    pure $ prependPath (symbolVal $ Proxy @path) . makeRequest

-- | Instance for path capture
instance
  ( ToHttpApiData a
  , HasGen a gens
  , GenRequest api gens
  ) => GenRequest (Capture' modifiers sym a :> api) gens where
    genRequest _ gens = do
      capture <- toUrlPiece <$> getGen @a @gens gens
      makeRequest <- genRequest (Proxy @api) gens
      pure $ prependPath capture . makeRequest

-- | Instance for capture rest of path, e.g:
--
-- @
-- type Api = "cats" :> CaptureAll "rest" Text :> Get '[JSON] [Cat]
-- @
--
-- For simplicity this will generate a number of paths from 0 to 10 linearly
--
instance
  ( ToHttpApiData a
  , HasGen a gens
  , GenRequest api gens
  ) => GenRequest (CaptureAll sym a :> api) gens where
    genRequest _ gens = do
      captures <- Gen.list (Range.linear 0 10) (getGen @a @gens gens)
      makeRequest <- genRequest (Proxy @api) gens
      pure $ \baseUrl ->
        foldr (prependPath . toUrlPiece) (makeRequest baseUrl) captures

-- | Instance for headers
--
-- /Note: this instance currently makes all headers mandatory/
instance
  ( HasGen header gens
  , KnownSymbol headerName
  , ToHttpApiData header
  , GenRequest api gens
  ) => GenRequest (Header' mods headerName header :> api) gens where
    genRequest _ gens = do
      let headerName = CI.mk . cs . symbolVal $ Proxy @headerName
      header <- getGen @header @gens gens
      makeRequest <- genRequest (Proxy @api) gens
      pure $ addHeader headerName (toHeader header) . makeRequest

-- | Instance for request body
instance
  ( AllMimeRender contentTypes body
  , HasGen body gens
  , GenRequest api gens
  ) => GenRequest (ReqBody' mods contentTypes body :> api) gens where
    genRequest _ gens = do
      newBody <- getGen @body @gens gens

      (contentType, body) <-
        Gen.element $ allMimeRender (Proxy @contentTypes) newBody

      makeRequest <- genRequest (Proxy @api) gens

      pure $ setBody body
           . addHeader "Content-Type" (renderHeader contentType)
           . makeRequest

-- | Instnace for capturing verb e.g. @POST@ or @GET@
instance
  ( ReflectMethod method
  ) => GenRequest (Verb method status contentTypes body) gens where
    genRequest _ _ =
      pure $ \baseUrl -> defaultRequest
        { host = cs . baseUrlHost $ baseUrl
        , port = baseUrlPort baseUrl
        , secure = baseUrlScheme baseUrl == Https
        , method = reflectMethod (Proxy @method)
        }

setBody :: LBS.ByteString -> Request -> Request
setBody body oldReq = oldReq { requestBody = RequestBodyLBS body }

addHeader :: HeaderName -> BS.ByteString -> Request -> Request
addHeader name value oldReq =
  let
    headers = (name, value) : requestHeaders oldReq
  in
    oldReq { requestHeaders = headers }

-- | Helper function for prepending a new URL piece
prependPath :: ConvertibleStrings s BS.ByteString => s -> Request -> Request
prependPath new oldReq =
  let
    partialUrl = BS.dropWhile (== BS.c2w '/') . path $ oldReq
    urlPieces = filter (not . BS.null) [cs new, partialUrl]
  in
    oldReq { path = "/" <> BS.intercalate "/" urlPieces }
