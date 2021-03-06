import Control.Exception (try, SomeException)
import Control.Concurrent
import Control.Concurrent.TxEvent
import Network as Network
import Data.ByteString (hPut)
import Data.HashMap.Strict as HM
import Data.List (intercalate)
import Data.Unique
import System.IO as IO
import Stomp.Frames hiding (getTransaction)
import Stomp.Frames.Router
import Stomp.Frames.IO
import qualified Stomp.TLogger as TLog
import Stomp.Util

-- |A SubId represents a unique subscription identifier
type SubId = String

-- |A TxId represents a unique transaction identifier
type TxId  = String

-- |A HashMap which contains mappings from SubIds to active subscriptions
type Subscriptions = HashMap SubId Subscription

-- |Represents an active client subscription
data Subscription = Subscription SubId String (SChan FrameEvt) AckType

-- |A Session is either Disconnected or represents an open connection with a STOMP broker. ExitApp indicates that the application should exit.
data Session = Disconnected TLog.Logger | 
               Session FrameHandler String String TLog.Logger RequestHandler (Maybe TxId) (SChan Event) (SChan FrameEvt) (SChan SubscriptionUpdate) | 
               ExitApp TLog.Logger 

-- |Indicates the types of event that can be processed by the main loop.
data Event   = GotInput String | GotFrameEvt FrameEvt AckType | ServerDisconnect

data SubscriptionUpdate = Subscribed SubId Subscription | 
                          Unsubscribed String | 
                          Received FrameEvt AckType | 
                          GetSubInfo (SChan Subscriptions) |
                          ClearSubs

instance Show Session where
    show (Session h ip port _ _ _ _ _ _) = "Connected to broker at " ++ ip ++ ":" ++ port
    show (Disconnected _)           = "Session is not connected"

instance Show Subscription where
    show (Subscription subId dest _ ackType) = 
        "\nSubscription ID: " ++ subId ++ 
        "\nDestination: " ++ dest ++ 
        "\nAck type: " ++ (show ackType)

-- |Given a Logger, display a "stomp> " prompt
stompPrompt :: TLog.Logger -> IO ()
stompPrompt console = TLog.prompt console "stomp> "

helpText :: String
helpText = "session                       Display information about the active session\n" ++
           "subs                          Display information about the active subscriptions\n" ++
           "connect <host> <ip>           Connect to the STOMP broker at the given host/ip\n" ++
           "disconnect                    Gracefully terminate the active session\n" ++
           "send <dest> <msg>             Send a message to the given destination\n" ++
           "sendr <dest> <rid> <msg>      Send a message to the given destination and request a\n" ++
           "                              receipt with the given receipt ID\n" ++
           "loopsend <n> <dest> <msg>     Send a message n times to the given destination\n" ++
           "subscribe <dest>              Subscribe to the given destination\n" ++
           "unsubscribe <dest>|<subid>    Unsubscribe from the given destination; supports passing\n" ++
           "                              either the destination name or subscription ID\n" ++
           "begin <txid>                  Begin a transaction using the given transaction ID;\n" ++
           "                              all send and sendr requests will be added to the transaction\n" ++
           "                              until it is either commited or aborted\n" ++
           "commit <txid>                 Commit the in-progress transaction\n" ++
           "abort <txid>                  Abort the in-progress transaction\n" ++
           "exit                          Gracefully terminate the active session and exit\n" ++
           "                              the application\n" ++
           "help                          Display this help text\n"


-- |Initialize the client
main :: IO ()
main = do
    hSetBuffering stdout NoBuffering
    console   <- TLog.initLogger stdout
    eventChan <- sync newSChan 
    inputChan <- sync newSChan
    subChan   <- sync newSChan
    forkIO $ inputLoop eventChan inputChan
    forkIO $ subscriptionLoop subChan eventChan HM.empty console
    TLog.prompt console "stomp> "
    sessionLoop (Disconnected console) eventChan inputChan subChan

-- |Stateful loop that tracks session information
sessionLoop :: Session -> SChan Event -> SChan String -> SChan SubscriptionUpdate -> IO ()
sessionLoop session eventChan inputChan subChan = do
    event    <- sync $ recvEvt eventChan
    session' <- processEvent event eventChan subChan inputChan session
    case session' of
        ExitApp _ -> sLog session' "Goodbye!"
        _         -> do
            stompPrompt (getLogger session')
            sessionLoop session' eventChan inputChan subChan

-- |Blocks waiting for input from stdin. When a line of input is received, sends an event on the appropriate channel.
-- The 'eventChan' is for the main prompt workflow; the inputChan is for nested prompts triggered by other events,
-- e.g. when frame processing requires the user to send an acknowledgement.
inputLoop :: SChan Event -> SChan String ->  IO ()
inputLoop eventChan inputChan = do
    input <- getLine
    sync $ (sendEvt eventChan (GotInput input)) `chooseEvt` (sendEvt inputChan input)
    inputLoop eventChan inputChan

-- |State management loop that holds the active Subscriptions for the session and handles updates as they are received
-- on the subscription channels.
subscriptionLoop :: SChan SubscriptionUpdate -> SChan Event -> Subscriptions -> TLog.Logger -> IO ()
subscriptionLoop subChan eventChan subscriptions console  = do
    update         <- sync $ (recvEvt subChan) `chooseEvt` (subChoiceEvt subscriptions)
    subscriptions' <- handleSubscriptionUpdate update subscriptions console eventChan
    subscriptionLoop subChan eventChan subscriptions' console

-- |Composite subscription choice event to receive a subscription update on any of the available channels.
subChoiceEvt :: Subscriptions -> Evt SubscriptionUpdate
subChoiceEvt subs = HM.foldr partialSubChoiceEvt neverEvt subs

-- |Partial Evt function to build a composite subscription choice event.
partialSubChoiceEvt :: Subscription -> Evt SubscriptionUpdate -> Evt SubscriptionUpdate
partialSubChoiceEvt (Subscription _ _ evtChan ackType) = chooseEvt $ (recvEvt evtChan) `thenEvt` (\frameEvt -> alwaysEvt (Received frameEvt ackType))

-- |Handle a SubscriptionUpdate.
handleSubscriptionUpdate :: SubscriptionUpdate -> Subscriptions -> TLog.Logger -> SChan Event -> IO Subscriptions
handleSubscriptionUpdate update subs console eventChan = case update of
    Subscribed subId newChan  -> return $ HM.insert subId newChan subs
    Unsubscribed subId        -> return $ removeSub subId subs
    Received frameEvt ackType -> do { sync $ sendEvt eventChan $ GotFrameEvt frameEvt ackType ; return subs }
    GetSubInfo responseChan   -> do { sync $ sendEvt responseChan subs ; return subs }
    ClearSubs                 -> return $ HM.empty

removeSub :: String -> Subscriptions -> Subscriptions
removeSub subId subs = case HM.lookup subId subs of
    Just sub -> HM.delete subId subs
    Nothing  -> case findKey subId (HM.elems subs) of
        Just key -> HM.delete key subs
        Nothing  -> subs

findKey :: String -> [Subscription] -> Maybe String
findKey  _ [] = Nothing
findKey subName ((Subscription subId subName' _ _):rest)
    | subName == subName' = Just subId
    | otherwise           = findKey subName rest

-- |Handle a FrameEvt
handleFrameEvt :: FrameEvt -> AckType -> Session -> SChan String -> SChan SubscriptionUpdate -> IO Session
handleFrameEvt frameEvt ackType session inputChan subChan = do    
    case frameEvt of
        NewFrame frame -> do
            sLog session $ "\n\nReceived message from destination " ++ (_getDestination frame)
            sLog session (show frame)
            case ackType of
                Auto -> return session
                _    -> do { handleAck frame ackType session inputChan ; return session }
        Heartbeat      -> return session
        GotEof         -> do
            sLog session $ "Server disconnected unexpectedly."
            disconnectSession session
        ParseError msg -> do
            sLog session $ "There was an issue parsing the received frame: " ++ msg
            return session

-- |Handle acknowledgement for a given Frame
handleAck :: Frame -> AckType -> Session -> SChan String -> IO ()
handleAck frame ackType session inputChan = do
    sPrompt session "\nWould you like to acknowledge the frame? [y(es)/n(o)/i(gnore)] "
    input <- sync $ recvEvt inputChan
    case input of
        "y" -> sendAck frame session
        "n" -> sendNack frame session
        "i" -> return ()
        _   -> do { sLog session "Invalid response" ; handleAck frame ackType session inputChan }

-- |Send an ACK response for a given Frame
sendAck :: Frame -> Session -> IO ()
sendAck frame session = do
    sendFrame session $ ack (_getAck frame)

-- |Send a NACK response for a given Frame
sendNack :: Frame -> Session -> IO ()
sendNack frame session = do
    sendFrame session $ nack (_getAck frame)

-- |Process an Event and return the updated Session that is the result of said processing.
processEvent :: Event -> SChan Event -> SChan SubscriptionUpdate -> SChan String -> Session -> IO Session
processEvent event eventChan subChan inputChan session = case event of
    GotInput input -> do
        result <- try (processInput (tokenize " " input) session eventChan subChan) :: IO (Either SomeException Session)
        session' <-
            case result of 
                Left exception -> do
                    sLog session ("[ERROR] " ++ (show exception))
                    return session
                Right session'' -> return session''
        return session'
    GotFrameEvt frameEvt ackType -> do
        session' <- handleFrameEvt frameEvt ackType session inputChan subChan
        return session'

-- |Process input given on the command-line
processInput :: [String] -> Session -> (SChan Event) -> SChan SubscriptionUpdate -> IO Session

-- process blank input (return press)
processInput [] session _ _ = return session

-- session command
processInput ("session":[]) session eventChan _ = do
    sLog session $ show session
    return session

-- connect command
processInput ("connect":ip:p:[]) session@(Disconnected _) eventChan subChan = do
    newHandle <- Network.connectTo ip (portFromString p)
    hSetBuffering newHandle NoBuffering
    frameHandler <- initFrameHandler newHandle
    put frameHandler $ connect "nohost" 4000 0
    response <- get frameHandler
    case response of
        (NewFrame frame@(Frame CONNECTED _ _)) -> do
            sLog session $ "Connected to " ++ ip ++ " on port " ++ p
            (serverSend, clientSend) <- return $ getHeartbeat frame
            updateHeartbeat frameHandler (1000 * clientSend)
            requestHandler <- initFrameRouter frameHandler
            responseChan   <- requestResponseEvents requestHandler
            return $ Session frameHandler ip p (getLogger session) requestHandler Nothing eventChan responseChan subChan
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
processInput ("connect":_:_:[]) session _ _ = do
    sLog session "Please disconnect from your current session before initiating a new one"
    return session

-- disconnect command
processInput ("disconnect":[]) session@(Disconnected _) _ _ = do
    sLog session "You are not currently connected to a session"
    return session
processInput ("disconnect":[]) session _ _ = gracefulDisconnect session

-- send command
processInput ("send":_) session@(Disconnected _) _ _ = do
    sLog session "You must initiate a connection before sending a message"
    return session
processInput ("send":queue:message) session _ _ = do
    sendFrame session $ addTransactionHeaderIfNeeded (sendText (intercalate " " message) queue) session
    return session

-- sendr (send with receipt request) command
processInput ("sendr":_) session@(Disconnected _) _ _ = do
    sLog session "You must initiate a connection before sending a message"
    return session
processInput ("sendr":queue:receiptId:message) session _ _ = do
    frame <- return $ addReceiptHeader receiptId (sendText (intercalate " " message) queue)
    sendFrame session (addTransactionHeaderIfNeeded frame session)
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
        Heartbeat -> do
            sLog session $ "Got hearbeat from server"
            return session
        GotEof -> do
            sLog session "Server disconnected unexpectedly"
            disconnectSession session
        ParseError msg -> do
            sLog session $ "There was an issue parsing the received frame: " ++ msg
            disconnectSession session

-- send the same message n times
processInput ("loopsend":_) session@(Disconnected _) _ _ = do
    sLog session "You must initiate a connection before sending a message"
    return session
processInput ("loopsend":n:q:m) session _ _ = do
    loopSend (sendText (intercalate " " m) q) session (fromIntegral ((read n)::Int))

-- subscribe to a new destination
processInput ("subscribe":_) session@(Disconnected _) _ _ = do
    sLog session "You must initiate a connection before adding a subscription"
    return session
processInput ("subscribe":dest:[]) session _ subChan = do
    uniqueId   <- newUnique
    subId      <- return (show $ hashUnique uniqueId)
    sendFrame session $ subscribe subId dest ClientIndividual
    frameChan  <- requestSubscriptionEvents (getRequestHandler session) subId
    forkIO $ sync $ sendEvt subChan (Subscribed subId (Subscription subId dest frameChan ClientIndividual))
    return session

-- unsubscribe from a destination
processInput ("unsubscribe":_) session@(Disconnected _) _ _ = do
    sLog session "You must initiate a connection before unsubscribing"
    return session
processInput ("unsubscribe":subId:[]) session _ subChan = do
    sendFrame session $ unsubscribe subId
    forkIO $ sync $ sendEvt subChan (Unsubscribed subId)
    return session

-- begin a transaction; all "send" commands between this command and a subsequent abort or commit will be part of the transaction.
processInput ("begin":_) session@(Disconnected _) _ _ = do
    sLog session "You must initiate a connection before initiating a transaction"
    return session
processInput ("begin":txid:[]) session _ _ =
    case getTransaction session of
        Just txid -> do
            sLog session $ "Transaction " ++ txid ++ " is already in progress!"
            return session
        Nothing -> do
            sendFrame session $ begin txid
            sLog session $ "Initialized new transaction with transaction id " ++ txid
            return (newTransaction session txid)

-- commit a transaction
processInput ("commit":_) session@(Disconnected _) _ _ = do
    sLog session "You must initiate a connection before committing a transaction"
    return session
processInput ("commit":[]) session _ _ =
    case getTransaction session of
        Just txid -> do
            sendFrame session $ commit txid
            sLog session $ "Committed transaction with transaction id " ++ txid
            return $ endTransaction session
        Nothing -> do
            sLog session "There is no transaction in progress"
            return session

-- abort the active transaction
processInput ("abort":_) session@(Disconnected _) _ _ = do
    sLog session "You must initiate a connection before aborting a transaction"
    return session
processInput ("abort":[]) session _ _ =
    case getTransaction session of
        Just txid -> do
            sendFrame session $ abort txid
            sLog session $ "Aborted transaction with transaction id " ++ txid
            return $ endTransaction session
        Nothing   -> do
            sLog session "There is no transaction in progress"
            return session

-- list active subscriptions
processInput ("subs":_) session@(Disconnected _) _ _ = do
    sLog session "You must initiate a connection first"
    return session
processInput ("subs":[]) session _ subChan = do
    responseChan  <- sync newSChan
    sync $ sendEvt subChan (GetSubInfo responseChan)
    subscriptions <- sync $ recvEvt responseChan
    sLog session $ "\nTotal subscriptions: " ++ (show $ HM.size subscriptions)
    mapM_ (showSubInfo session) subscriptions
    return session

-- exit the application
processInput ("exit":[]) session eventChan _ = do
    gracefulDisconnect session
    return $ ExitApp (getLogger session)

processInput ("help":[]) session _ _ = do
    sLog session helpText
    return session

-- any other input pattern is considered an error
processInput _ session _ _ = do
    sLog session "Unrecognized or malformed command; use 'help' to display the list of commands\n"
    sLog session helpText
    return session

-- |Disconnect gracefully from a session
gracefulDisconnect :: Session -> IO Session
gracefulDisconnect session@(Disconnected _) = return session
gracefulDisconnect session@(ExitApp _)      = return session
gracefulDisconnect session                  = do
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
        Heartbeat -> do
            sLog session "Got a heartbeat from the server"
        ParseError msg -> do
            sLog session $ "There was an issue parsing the received frame: " ++ msg
        GotEof -> do
            sLog session "Server disconnected before a response was received"
    disconnectSession session

-- log the information for one Subscription
showSubInfo :: Session -> Subscription -> IO ()
showSubInfo session subscription = sLog session (show subscription)

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
disconnectSession session = case session of
    (Session _ _ _ _ _ _ _ _ _) -> do
        close $ getHandler session
        sync $ sendEvt (getSubChan session) ClearSubs
        return (Disconnected (getLogger session))
    _ -> return session

-- |Get the FrameHandler from the Session
getHandler :: Session -> FrameHandler
getHandler (Session handler _ _ _ _ _ _ _ _) = handler

-- |Get the (console) Logger for the Session
getLogger :: Session -> TLog.Logger
getLogger (Session handle _ _ logger _ _ _ _ _) = logger
getLogger (Disconnected logger) = logger
getLogger (ExitApp      logger) = logger

-- |Get the RequestHandler for the Session
getRequestHandler :: Session -> RequestHandler
getRequestHandler (Session _ _ _ _ requestHandler _ _ _ _) = requestHandler

-- |Get the FrameEvt channel for the Session
getResponseChan :: Session -> (SChan FrameEvt)
getResponseChan (Session _ _ _ _ _ _ _ chan _) = chan

getSubChan :: Session -> (SChan SubscriptionUpdate)
getSubChan (Session _ _ _ _ _ _ _ _ chan) = chan

-- |Get a response Frame from the Session
getResponseFrame :: Session -> IO FrameEvt
getResponseFrame session = sync $ recvEvt (getResponseChan session)

-- |Log a message to the session
sLog :: Session -> String -> IO ()
sLog session message = TLog.log (getLogger session) message

-- |Log a message to the session, but do not append a newline character (e.g. for a prompt)
sPrompt :: Session -> String -> IO ()
sPrompt session message = TLog.prompt (getLogger session) message

-- |Add the TxId to the Session
newTransaction :: Session -> TxId -> Session
newTransaction (Session fh ip p logger rh _ eventChan frameChan subChan) txid = Session fh ip p logger rh (Just txid) eventChan frameChan subChan

-- |Remove the TxId from the Session
endTransaction :: Session -> Session
endTransaction (Session fh ip p logger rh _ eventChan frameChan subChan) = Session fh ip p logger rh Nothing eventChan frameChan subChan

-- |Get the TxId for the Session
getTransaction :: Session -> Maybe TxId
getTransaction (Session _ _ _ _ _ tx _ _ _) = tx

-- |If the Session is currently in the midst of a transaction, add the transaction header
addTransactionHeaderIfNeeded :: Frame -> Session -> Frame
addTransactionHeaderIfNeeded frame (Session _ _ _ _ _ Nothing _ _ _) = frame
addTransactionHeaderIfNeeded frame (Session _ _ _ _ _ (Just txid) _ _ _) = addFrameHeaderFront (txHeader txid) frame
