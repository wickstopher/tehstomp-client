import Control.Exception (try, SomeException)
import Control.Concurrent
import Control.Concurrent.TxEvent
import Network as Network
import Data.ByteString (hPut)
import Data.List (intercalate)
import Data.Unique
import System.IO as IO
import Stomp.Frames
import Stomp.Frames.Router
import Stomp.Frames.IO
import qualified Stomp.TLogger as TLog
import Stomp.Util

-- A Session is either Disconnected or represents an open connection with a STOMP broker.
data Session = Disconnected TLog.Logger | Session FrameHandler String String TLog.Logger RequestHandler (SChan FrameEvt) 

data Event   = GotInput String

instance Show Session where
    show (Session h ip port _  _ _) = "Connected to broker at " ++ ip ++ ":" ++ port
    show (Disconnected _)           = "Session is not connected"

-- Initialize the client
main :: IO ()
main = do
    hSetBuffering stdout NoBuffering
    console   <- TLog.initLogger stdout
    eventChan <- sync newSChan 
    inputChan <- sync newSChan
    forkIO $ inputLoop eventChan inputChan
    TLog.prompt console "stomp> "
    sessionLoop (Disconnected console) eventChan inputChan 

sessionLoop :: Session -> SChan Event -> SChan String -> IO ()
sessionLoop session eventChan inputChan = do
    event    <- sync $ recvEvt eventChan
    session' <- processEvent event session
    sessionLoop session' eventChan inputChan

inputLoop :: SChan Event -> SChan String ->  IO ()
inputLoop eventChan inputChan = do
    input <- getLine
    sync $ (sendEvt eventChan (GotInput input)) `chooseEvt` (sendEvt inputChan input)
    inputLoop eventChan inputChan

processEvent :: Event -> Session -> IO Session
processEvent event session = case event of
    GotInput input -> do
        result <- try (processInput (tokenize " " input) session) :: IO (Either SomeException Session)
        session' <-
            case result of 
                Left exception -> do
                    sLog session ("[ERROR] " ++ (show exception))
                    return session
                Right session'' -> return session''
        sPrompt session "stomp> "
        return session'

-- |Process input given on the command-line
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
        (NewFrame (Frame CONNECTED _ _)) -> do
            sLog session $ "Connected to " ++ ip ++ " on port " ++ p
            requestHandler <- initFrameRouter frameHandler
            responseChan   <- requestResponseEvents requestHandler
            return $ Session frameHandler ip p (getLogger session) requestHandler responseChan
        (NewFrame (Frame ERROR _ body)) -> do
            sLog session "There was a problem connecting: "
            sLog session (show body)
            return session
        ParseError msg -> do
            sLog session $ "There was an issue parsing the received frame: " ++ msg
            return session
        GotEof -> do
            sLog session "The server disconnected before connections could be negotiated"
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
        (NewFrame frame@(Frame RECEIPT _ _)) -> do
            case (getReceiptId frame) of 
                Just "recv-tehstomp-disconnect" -> sLog session "Successfully disconnected from the session"
                otherwise                       -> sLog session $ (show frame) -- TODO: throw Exception here?
        (NewFrame (Frame ERROR _ body)) -> do
            sLog session "There was a problem: "
            sLog session (show body)
        (NewFrame frame)               -> do
            sLog session $ "Got an unexpected frame type: " ++ (show $ getCommand frame)
        ParseError msg -> do
            sLog session $ "There was an issue parsing the received frame: " ++ msg
        GotEof -> do
            sLog session "Server disconnected before a response was received"
    disconnectSession session

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
        (NewFrame frame@(Frame RECEIPT _ _)) -> do
            case (getReceiptId frame) of
                Just receiptId -> sLog session $ "Received a receipt for message " ++ receiptId   
                Nothing        -> sLog session $ (show frame) -- TODO: throw Exception here
            return session
        (NewFrame (Frame ERROR _ body)) -> do
            sLog session "There was a problem: "
            sLog session (show body)
            return session
        (NewFrame frame) -> do
            sLog session $ "Got an unexpected frame type: " ++ (show $ getCommand frame)
            return session
        GotEof -> do
            sLog session "Server disconnected unexpectedly"
            disconnectSession session
        ParseError msg -> do
            sLog session $ "There was an issue parsing the received frame: " ++ msg
            disconnectSession session

-- send the same message n times
processInput ("loopsend":_) session@(Disconnected _) = do
    sLog session "You must initiate a connection before sending a message"
    return session
processInput ("loopsend":n:q:m) session = do
    loopSend (sendText (intercalate " " m) q) session (fromIntegral ((read n)::Int))

processInput ("subscribe":_) session@(Disconnected _) = do
    sLog session "You must initiate a connection before adding a subscription"
    return session
processInput ("subscribe":dest:[]) session = do
    uniqueId <- newUnique
    subId    <- return (show $ hashUnique uniqueId)
    sendFrame session $ subscribe subId dest ClientIndividual
    subChan  <- requestSubscriptionEvents (getRequestHandler session) subId
    forkIO $ subscriptionListener (getLogger session) subChan dest subId
    return session

-- any other input pattern is considered an error
processInput _ session = do
    sLog session "Unrecognized or malformed command"
    return session

subscriptionListener :: TLog.Logger -> (SChan FrameEvt) -> String -> String -> IO ()
subscriptionListener console subChan dest subId = do
    frameEvt <- sync $ recvEvt subChan
    TLog.prompt console $ "\n\n[subscription " ++ subId ++ "] "
    case frameEvt of
        NewFrame frame -> do
            TLog.log console $ "Received message from destination " ++ dest
            TLog.log console (show frame)
            TLog.prompt console "\nstomp> "
            subscriptionListener console subChan dest subId
        GotEof         -> do
            TLog.log console $ "Server disconnected unexpectedly."
            TLog.prompt console "\nstomp> "
            return ()
        ParseError msg -> do
            TLog.log console $ "There was an issue parsing the received frame: " ++ msg
            TLog.prompt console "\nstomp> "
            return ()

-- |Send a Frame to the Session n times
loopSend :: Frame -> Session -> Int -> IO Session
loopSend _ session 0 =  do return session
loopSend frame session n = do
    sendFrame session frame
    loopSend frame session (n-1)

-- |Convert a String to a PortID
portFromString :: String -> PortID
portFromString s = PortNumber (fromIntegral ((read s)::Int))

-- |Send a Frame to the Session
sendFrame :: Session -> Frame -> IO ()
sendFrame session frame = put (getHandler session) frame

-- |Disconnect the Session
disconnectSession :: Session -> IO Session
disconnectSession session = do
    close $ getHandler session
    return (Disconnected (getLogger session))

-- |Get the FrameHandler from the Session
getHandler :: Session -> FrameHandler
getHandler (Session handler _ _ _ _ _) = handler

-- |Get the (console) Logger for the Session
getLogger :: Session -> TLog.Logger
getLogger (Session handle _ _ logger _ _) = logger
getLogger (Disconnected logger) = logger

-- |Get the RequestHandler for the Session
getRequestHandler :: Session -> RequestHandler
getRequestHandler (Session _ _ _ _ requestHandler _) = requestHandler

-- |Get the FrameEvt channel for the Session
getResponseChan :: Session -> (SChan FrameEvt)
getResponseChan (Session _ _ _ _ _ chan) = chan

-- |Get a response Frame from the Session
getResponseFrame :: Session -> IO FrameEvt
getResponseFrame session = sync $ recvEvt (getResponseChan session)

-- |Log a message to the session
sLog :: Session -> String -> IO ()
sLog session message = TLog.log (getLogger session) message

-- |Log a message to the session, but do not append a newline character (e.g. for a prompt)
sPrompt :: Session -> String -> IO ()
sPrompt session message = TLog.prompt (getLogger session) message