{-# OPTIONS_GHC -Wall #-}
{-# Language DeriveDataTypeable #-}

module Main ( main ) where

import qualified Control.Concurrent as CC
import Control.Monad ( when, forever )
import Data.ByteString.Char8 ( pack )
import Data.Serialize
import Data.Vector ( Vector )
import qualified System.ZMQ3 as ZMQ
import System.Console.CmdArgs ( (&=), Data, Typeable )
import qualified System.Console.CmdArgs as CA

import Dyno.Server.Server ( runPlotter, newChannel )
import Dyno.DirectCollocation.Dynamic

import GliderShared ( gliderUrl, gliderChannelName )

sub :: String -> ((DynCollTraj (Vector Double), CollTrajMeta) -> IO ()) -> String -> IO ()
sub ip' writeChan name = ZMQ.withContext $ \context ->
  ZMQ.withSocket context ZMQ.Sub $ \subscriber -> do
    ZMQ.connect subscriber ip'
    ZMQ.subscribe subscriber (pack name)
    forever $ do
      _ <- ZMQ.receive subscriber
      mre <- ZMQ.moreToReceive subscriber
      when mre $ do
        msg <- ZMQ.receive subscriber
        let decoded :: (DynCollTraj (Vector Double), CollTrajMeta)
            decoded = case decode msg of
              Left err -> error err
              Right t -> t
        writeChan decoded

main :: IO ()
main = do
  args <- CA.cmdArgs (myargs &= CA.program "dynoplot")
  let ip' = ip args
      channel' = channel args
  putStrLn $ "using ip \""++ip'++"\""
  putStrLn $ "using channel \""++channel'++"\""

  (c0, writeMe) <- newChannel channel'

  listenerTid0 <- CC.forkIO (sub ip' writeMe channel')
  runPlotter c0 [listenerTid0]

data VisArgs = VisArgs { ip :: String
                       , channel :: String
                       } deriving (Show, Data, Typeable)

myargs :: VisArgs
myargs = VisArgs { ip = gliderUrl               &= CA.help "an IP address" &= CA.typ "ADDRESS"
                 , channel = gliderChannelName  &= CA.help "zmq channel name"
                 } &= CA.summary "plotter for dynobud OCPs"
