import Control.Exception (try, SomeException)
import Control.Concurrent.TxEvent
import Network as Network
import Data.ByteString (hPut)
import Data.List (intercalate)
import System.IO as IO
import Stomp.Frames
import Stomp.Frames.IO
import qualified Stomp.TLogger as TLog
import Stomp.Util
import FrameRouter

data Session = Session FrameHandler String String TLog.Logger Notifier ResponseChannel | Disconnected TLog.Logger

instance Show Session where
    show (Session h ip port _  _ _) = "Connected to broker at " ++ ip ++ ":" ++ port
    show (Disconnected _)        = "Session is not connected"

main :: IO Session
main = do
    hSetBuffering stdout NoBuffering
    console  <- TLog.initLogger stdout
    prompt $ Disconnected console

prompt :: Session -> IO Session
prompt session = do
    sPrompt session "stomp> "
    input <- getLine
    result <- try (processInput (tokenize " " input) session) :: IO (Either SomeException Session)
    case result of 
        Left exception -> do
            sLog session ("[ERROR] " ++ (show exception))
            prompt session
        Right session' -> prompt session'

processInput :: [String] -> Session -> IO Session

-- process blank input (return press)
processInput [] session = do return session

-- session command
processInput ("session":[]) session = do
    sLog session $ show session
    return session

-- connect command
processInput ("connect":ip:p:[]) session@(Disconnected _) = do
    newHandle <- Network.connectTo ip (portFromString p)
    hSetBuffering newHandle NoBuffering
    frameHandler <- initFrameHandler newHandle
    put frameHandler $ connect "nohost"
    response <- get frameHandler
    case response of
        (Frame CONNECTED _ _) -> do
            sLog session $ "Connected to " ++ ip ++ " on port " ++ p
            notifier     <- initFrameRouter frameHandler
            responseChan <- requestResponseEvents notifier
            return $ Session frameHandler ip p (getLogger session) notifier responseChan
        (Frame ERROR _ body) -> do
            sLog session "There was a problem connecting: "
            sLog session (show body)
            return session

processInput ("connect":_:_:[]) session = do
    sLog session "Please disconnect from your current session before initiating a new one"
    return session

-- disconnect command
processInput ("disconnect":[]) session@(Disconnected _) = do
    sLog session "You are not currently connected to a session"
    return session
processInput ("disconnect":[]) session = do
    sendFrame session $ disconnect "recv-tehstomp-disconnect"
    response <- getResponseFrame session
    case response of
        (Frame RECEIPT _ _) -> do
            case (getReceiptId response) of 
                Just "recv-tehstomp-disconnect" -> sLog session "Successfully disconnected from the session"
                otherwise                       -> sLog session $ (show response) -- TODO: throw Exception here?
        (Frame ERROR _ body) -> do
            sLog session "There was a problem: "
            sLog session (show body)
            -- TODO: throw Exception here?
    disconnectSession session
    return (Disconnected (getLogger session))

-- send command
processInput ("send":_) session@(Disconnected _) = do
    sLog session "You must initiate a connection before sending a message"
    return session
processInput ("send":queue:message) session = do
    sendFrame session $ sendText (intercalate " " message) queue
    return session

-- sendr (send with receipt request) command
processInput ("sendr":_) session@(Disconnected _) = do
    sLog session "You must initiate a connection before sending a message"
    return session
processInput ("sendr":queue:receiptId:message) session = do
    sendFrame session $ addReceiptHeader receiptId (sendText (intercalate " " message) queue)
    response <- getResponseFrame session
    case response of
        (Frame RECEIPT _ _) -> do
            case (getReceiptId response) of
                Just receiptId -> sLog session $ "Received a receipt for message " ++ receiptId   
                Nothing        -> sLog session $ (show response) -- TODO: throw Exception here
        (Frame ERROR _ body) -> do
            sLog session "There was a problem: "
            sLog session (show body)
        -- TODO: throw Exception here?
    return session

-- send the same message n times
processInput ("loopsend":_) session@(Disconnected _) = do
    sLog session "You must initiate a connection before sending a message"
    return session
processInput ("loopsend":n:q:m) session = do
    loopSend (sendText (intercalate " " m) q) session (fromIntegral ((read n)::Int))

-- any other input pattern is considered an error
processInput _ session = do
    sLog session "Unrecognized or malformed command"
    return session

loopSend :: Frame -> Session -> Int -> IO Session
loopSend _ session 0 =  do return session
loopSend frame session n = do
    sendFrame session frame
    loopSend frame session (n-1)

portFromString :: String -> PortID
portFromString s = PortNumber (fromIntegral ((read s)::Int))

sendFrame :: Session -> Frame -> IO ()
sendFrame session frame = put (getHandler session) frame

disconnectSession :: Session -> IO ()
disconnectSession session = close $ getHandler session

getHandler :: Session -> FrameHandler
getHandler (Session handler _ _ _ _ _) = handler

getLogger :: Session -> TLog.Logger
getLogger (Session handle _ _ logger _ _) = logger
getLogger (Disconnected logger) = logger

getNotifier :: Session -> Notifier
getNotifier (Session _ _ _ _ notifier _) = notifier

getResponseChan :: Session -> ResponseChannel
getResponseChan (Session _ _ _ _ _ chan) = chan

getResponseFrame :: Session -> IO Frame
getResponseFrame session = sync $ recvEvt (getResponseChan session)

sLog :: Session -> String -> IO ()
sLog session message = TLog.log (getLogger session) message

sPrompt :: Session -> String -> IO ()
sPrompt session message = TLog.prompt (getLogger session) message