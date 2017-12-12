-- Demonstrates client failure to participate in heart-beating

import Control.Concurrent.TxEvent
import Stomp.Frames
import Stomp.Frames.IO
import Stomp.Increment
import Network as Network
import System.Environment
import System.IO

main :: IO ()
main = do
    args <- getArgs
    (ip, port) <- processArgs args
    handle <- Network.connectTo ip (portFromString port)
    hSetBuffering handle NoBuffering
    frameHandler <- initFrameHandler handle
    put frameHandler $ connect "nohost" 1000 1000
    response <- get frameHandler
    case response of 
        (NewFrame frame@(Frame CONNECTED _ _)) -> putStrLn $ "Connected to " ++ ip ++ " on port " ++ port
        otherwise                              -> error "There was a problem initiating the connection"
    updateHeartbeat frameHandler (2000 * 1000)
    incrementer <- newIncrementer
    receiveLoop frameHandler incrementer

receiveLoop :: FrameHandler -> Incrementer -> IO ()
receiveLoop frameHandler incrementer = do
    -- Not enough time!
    evt <- sync $ getEvtWithTimeOut frameHandler (500 * 1000)
    case evt of 
        Heartbeat  -> do
            putStrLn $ "Got a heartbeat from the server!"
            receiveLoop frameHandler incrementer
        otherwise  -> putStrLn $ "Got something other than a heartbeat: " ++ (show evt)

processArgs :: [String] -> IO (HostName, String)
processArgs _ = return ("localhost", "2323")

-- |Convert a String to a PortID
portFromString :: String -> PortID
portFromString s = PortNumber (fromIntegral ((read s)::Int))
