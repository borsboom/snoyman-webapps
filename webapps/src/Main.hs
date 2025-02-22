{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
module Main (main) where

import qualified Data.HashMap.Strict       as HM
import           Data.Maybe                (fromMaybe)
import qualified Data.Text                 as T
import qualified Data.Text.Encoding        as T
import           Network.HTTP.Client       (defaultManagerSettings, newManager)
import           Network.HTTP.ReverseProxy (ProxyDest (..),
                                            WaiProxyResponse (..), defaultOnExc,
                                            waiProxyTo)
import           Network.HTTP.Types        (status200, status404, status307)
import           Network.Wai               (requestHeaderHost, responseLBS, rawPathInfo, rawQueryString, responseBuilder)
import           Network.Wai.Handler.Warp  (run)
import           Network.Wai.Middleware.Gzip (gzip, def)
import           Text.Read                 (readMaybe)
import Data.Aeson (FromJSON (..), (.:), withObject)
import Data.Streaming.Network (bindRandomPortTCP)
import qualified Data.Yaml as Yaml
import Network.Socket (sClose)
import Control.Exception (throwIO)
import Control.Concurrent.Async (Concurrently (..))
import System.Environment (getEnvironment)
import System.Process (createProcess, proc, env, cwd, waitForProcess)
import qualified Data.ByteString as S
import Lucid
import Lucid.Html5
import Data.Functor.Identity (runIdentity)
import Control.Monad (forM_)

data Config port = Config
    { configApps :: ![App port]
    , configRedirects :: ![Redirect]
    , configIndexVhost :: !String
    , configTitle :: !T.Text
    }
    deriving (Show, Functor, Foldable, Traversable)
instance port ~ () => FromJSON (Config port) where
    parseJSON = withObject "Config" $ \o -> Config
        <$> o .: "apps"
        <*> o .: "redirects"
        <*> o .: "index-vhost"
        <*> o .: "title"

data App port = App
    { appVhost :: !String
    , appPort :: !port
    , appDir :: !FilePath
    , appExe :: !FilePath
    , appArgs :: ![String]
    , appDesc :: !T.Text
    }
    deriving (Show, Functor, Foldable, Traversable)
instance port ~ () => FromJSON (App port) where
    parseJSON = withObject "App" $ \o -> App
        <$> o .: "vhost"
        <*> pure ()
        <*> o .: "dir"
        <*> o .: "exe"
        <*> o .: "args"
        <*> o .: "desc"

data Redirect = Redirect
    { redSrc :: !String
    , redDst :: !String
    }
    deriving Show
instance FromJSON Redirect where
    parseJSON = withObject "Redirect" $ \o -> Redirect
        <$> o .: "src"
        <*> o .: "dst"

getRandomPort :: IO Int
getRandomPort = do
    (port, socket) <- bindRandomPortTCP "*"
    sClose socket
    return port

main :: IO ()
main = do
    cfg  <- Yaml.decodeFileEither "config/webapps.yaml"
        >>= either throwIO return
        >>= mapM (const getRandomPort)
    env0 <- getEnvironment
    let env1 = filter (\(k, _) -> k /= "PORT" && k /= "APPROOT") env0
    port <-
        case lookup "PORT" env0 of
            Nothing -> error "No PORT environment variable"
            Just sport ->
                case readMaybe sport of
                    Nothing -> error $ "Invalid port: " ++ sport
                    Just port -> return port
    runConcurrently $ foldr
        (\app c -> Concurrently (runWebApp env1 app) *> c)
        (Concurrently $ runProxy port cfg)
        (configApps cfg)

data Dest = Index | Port !Int | Host !S.ByteString

runProxy :: Int -> Config Int -> IO ()
runProxy proxyPort cfg = do
    manager <- newManager defaultManagerSettings
    putStrLn $ "Listening on: " ++ show proxyPort
    run proxyPort (middleware $ app manager)
  where
    vhosts = HM.insert (T.encodeUtf8 $ T.pack $ configIndexVhost cfg) Index
           $ HM.fromList $ map toPair (configApps cfg)
                        ++ map redToPair (configRedirects cfg)
    toPair App {..} = (T.encodeUtf8 $ T.pack appVhost, Port appPort)

    dispatch req = return $ fromMaybe defRes $ do
        vhost <- requestHeaderHost req
        res <- HM.lookup vhost vhosts
        return $ case res of
            Port port -> WPRProxyDest $ ProxyDest "localhost" port
            Host host -> WPRResponse $ responseLBS status307
                [ ("Location", getLocation host req)
                ]
                "Redirecting"
            Index -> WPRResponse $ responseBuilder
                status200
                [("Content-Type", "text/html; charset=utf-8")]
                (runIdentity $ execHtmlT $ indexHtml cfg)
    defRes = WPRResponse $ responseLBS status404 [] "Host not found"

    getLocation host req = S.concat
        [ "http://"
        , host
        , rawPathInfo req
        , rawQueryString req
        ]

    redToPair (Redirect src dst) =
        ( T.encodeUtf8 $ T.pack src
        , Host $ T.encodeUtf8 $ T.pack dst
        )

    app = waiProxyTo dispatch defaultOnExc

    middleware = gzip def

indexHtml :: Config a -> Html ()
indexHtml cfg =
    doctypehtml_ $ do
        head_ $ do
            title_ $ toHtml $ configTitle cfg
        body_ $ do
            h1_ $ toHtml $ configTitle cfg
            ul_ $ do
                forM_ (configApps cfg) $ \app -> do
                    let url = T.pack $ concat
                            [ "http://"
                            , appVhost app
                            , "/"
                            ]
                    li_ $ a_ [href_ url] $ toHtml $ appDesc app

runWebApp :: [(String, String)] -> App Int -> IO ()
runWebApp env0 App {..} = do
    (Nothing, Nothing, Nothing, ph) <- createProcess (proc appExe appArgs)
        { env = Just $ ("PORT", show appPort)
                     : ("APPROOT", "http://" ++ appVhost)
                     : env0
        , cwd = Just appDir
        }
    waitForProcess ph >>= throwIO
