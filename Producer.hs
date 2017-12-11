import Control.Concurrent.TxEvent
import Stomp.Frames
import Stomp.Frames.IO
import Network as Network
import System.Environment
import System.IO

main :: IO ()
main = do
    args <- getArgs
    (ip, port, dest, n) <- processArgs args
    handle <- Network.connectTo ip (portFromString port)
    hSetBuffering handle NoBuffering
    frameHandler <- initFrameHandler handle
    put frameHandler $ connect "nohost" 4000 0
    response <- get frameHandler
    case response of 
        (NewFrame frame@(Frame CONNECTED _ _)) -> putStrLn $ "Connected to " ++ ip ++ " on port " ++ port
        otherwise                              -> error "There was a problem initiating the connection"
    sendLoop dest frameHandler n



sendLoop :: String -> FrameHandler -> Int -> IO ()
sendLoop dest frameHandler n = do
    put frameHandler (sendText ("Hello, " ++ dest) dest)
    if n > 1 then
        sendLoop dest frameHandler (n - 1)
    else if n == -1 then do
        sendLoop dest frameHandler n
    else return ()


-- |Convert a String to a PortID
portFromString :: String -> PortID
portFromString s = PortNumber (fromIntegral ((read s)::Int))

processArgs :: [String] -> IO (HostName, String, String, Int)
processArgs(s:n:[]) = return ("localhost", "2323", s, (read n)::Int)
processArgs _ = error "Usage: producer <dest> <n>"