import Stomp.Frames
import Stomp.Frames.IO
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
    put frameHandler $ connect "nohost" 4000 0
    response <- get frameHandler
    case response of 
        (NewFrame frame@(Frame CONNECTED _ _)) -> putStrLn $ "Connected to " ++ ip ++ " on port " ++ port
        otherwise                              -> error "There was a problem initiating the connection"
    sendLoop dest frameHandler 100000

processArgs :: [String] -> IO (HostName, String, String)
processArgs _ = return ("localhost", "2323", "q1")

sendLoop :: String -> FrameHandler -> Integer -> IO ()
sendLoop dest frameHandler n = do
    put frameHandler (sendText ("Hello, " ++ dest) dest)
    if n > 1 then
        sendLoop dest frameHandler (n - 1)
    else return ()


-- |Convert a String to a PortID
portFromString :: String -> PortID
portFromString s = PortNumber (fromIntegral ((read s)::Int))