import Control.Exception (try, SomeException)
import Network as Network
import Data.ByteString (hPut)
import System.IO as IO
import Stomp.Frames
import Stomp.Frames.IO
import Stomp.Util

main :: IO (Maybe Handle)
main = do
    hSetBuffering stdout NoBuffering
    prompt Nothing

prompt :: Maybe Handle -> IO (Maybe Handle)
prompt handle = do
    putStr "<STOMP> "
    input <- getLine
    newHandle <- try (processInput (tokenize " " input) handle) :: IO (Either SomeException (Maybe Handle))
    case newHandle of 
        Left exception -> do
            putStrLn  ("Caught exception: " ++ (show exception))
            prompt handle
        Right newHandle -> prompt newHandle

processInput :: [String] -> Maybe Handle -> IO (Maybe Handle)
processInput [] handle = do return handle

processInput ("connect":ip:p:[]) handle = do
    newHandle <- Network.connectTo ip (portFromString p)
    hPut newHandle (frameToBytes $ connect "nohost")
    response <- parseFrame newHandle
    putStrLn (show response)
    return $ Just newHandle

processInput ("send":message:queue:[]) h@(Just handle) = do
    hPut handle (frameToBytes $ sendText message queue)
    return h
processInput ("send":_) Nothing = do
    putStrLn "You must initiate a connection before sending a message"
    return Nothing

processInput _ handle = do
    putStrLn "Unrecognized or malformed command"
    return handle

portFromString :: String -> PortID
portFromString s = PortNumber (fromIntegral ((read s)::Int))


