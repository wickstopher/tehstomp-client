import Stomp.Frames
import Stomp.Frames.IO
import Stomp.Increment
import Network as Network
import System.Environment
import System.IO

main :: IO ()
main = do
    args <- getArgs
    (ip, port, dest) <- processArgs args
    handle <- Network.connectTo ip (portFromString port)
    hSetBuffering handle NoBuffering
    frameHandler <- initFrameHandler handle
    put frameHandler $ connect "nohost" 0 0
    response <- get frameHandler
    case response of 
        (NewFrame frame@(Frame CONNECTED _ _)) -> putStrLn $ "Connected to " ++ ip ++ " on port " ++ port
        otherwise                              -> error "There was a problem initiating the connection"
    put frameHandler $ subscribe "xxx" "q1" Auto
    incrementer <- newIncrementer
    receiveLoop frameHandler incrementer

receiveLoop :: FrameHandler -> Incrementer -> IO ()
receiveLoop frameHandler incrementer = do
    evt <- get frameHandler
    case evt of 
        NewFrame f -> do
            i <- getNext incrementer
            putStrLn $ "Got a frame. Current count is : " ++ (show i)
            receiveLoop frameHandler incrementer
        Heartbeat  -> do
            putStrLn "Got a heartbeat"
            receiveLoop frameHandler incrementer
        otherwise  -> putStrLn $ "Got something other than a frame: " ++ (show evt)

processArgs :: [String] -> IO (HostName, String, String)
processArgs _ = return ("localhost", "2323", "q1")

-- |Convert a String to a PortID
portFromString :: String -> PortID
portFromString s = PortNumber (fromIntegral ((read s)::Int))