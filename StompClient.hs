import Control.Exception (try, SomeException)
import Network as Network
import Data.ByteString (hPut)
import Data.List (intercalate)
import System.IO as IO
import Stomp.Frames
import Stomp.Frames.IO
import Stomp.Util

data Session = Session Handle String String | Disconnected

instance Show Session where
    show (Session h ip port) = "Connected to broker at " ++ ip ++ ":" ++ port
    show Disconnected        = "Session is not connected"

main :: IO Session
main = do
    hSetBuffering stdout NoBuffering
    prompt Disconnected

prompt :: Session -> IO Session
prompt session = do
    putStr "<STOMP> "
    input <- getLine
    result <- try (processInput (tokenize " " input) session) :: IO (Either SomeException Session)
    case result of 
        Left exception -> do
            putStrLn  ("Caught exception: " ++ (show exception))
            prompt session
        Right session' -> prompt session'

processInput :: [String] -> Session -> IO Session
processInput [] session = do return session

processInput ("session":[]) session = do
    putStrLn $ show session
    return session

processInput ("connect":ip:p:[]) Disconnected = do
    newHandle <- Network.connectTo ip (portFromString p)
    hPut newHandle (frameToBytes $ connect "nohost")
    response <- parseFrame newHandle
    case response of
        (Frame CONNECTED _ _) -> do
            putStrLn $ "Connected to " ++ ip ++ " on port " ++ p
            return $ Session newHandle ip p
        (Frame ERROR _ body) -> do
            putStrLn "There was a problem connecting: "
            putStrLn (show body)
            return Disconnected

processInput ("send":_) Disconnected = do
    putStrLn "You must initiate a connection before sending a message"
    return Disconnected
processInput ("send":queue:message) session = do
    sendFrame session $ sendText (intercalate " " message) queue
    return session

processInput ("sendr":_) Disconnected = do
    putStrLn "You must initiate a connection before sending a message"
    return Disconnected
processInput ("sendr":queue:receiptId:message) session = do
    sendFrame session $ addReceiptHeader receiptId (sendText (intercalate " " message) queue)
    response <- receiveFrame session
    case response of
        (Frame RECEIPT _ _) -> do
            case (getReceiptId response) of
                Just receiptId -> putStrLn $ "Received a receipt for message " ++ receiptId   
                Nothing        -> putStrLn $ (show response)
        (Frame ERROR _ body) -> do
            putStrLn "There was a problem: "
            putStrLn (show body)
    return session

processInput _ session = do
    putStrLn "Unrecognized or malformed command"
    return session

portFromString :: String -> PortID
portFromString s = PortNumber (fromIntegral ((read s)::Int))

sendFrame :: Session -> Frame -> IO ()
sendFrame (Session handle _ _) frame = do hPut handle $ frameToBytes frame

receiveFrame :: Session -> IO Frame
receiveFrame (Session handle _ _) = parseFrame handle
