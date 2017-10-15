module FrameRouter (
    initFrameRouter,
    requestResponseEvents,
    requestSubscriptionEvents,
    Notifier
) where

import Control.Concurrent
import Control.Concurrent.TxEvent
import Data.HashMap.Strict as HM
import Stomp.Frames
import Stomp.Frames.IO

data Update        = ResponseRequest (SChan FrameEvt)  | 
                     SubscriptionRequest String (SChan FrameEvt) |
                     GotFrame Frame |
                     ServerDisconnected

data Notifier      = Notifier (SChan Update)

data Subscriptions = Subscriptions (HashMap String [SChan FrameEvt])

data FrameRouter   = FrameRouter (SChan Update) (SChan Update) [SChan FrameEvt] Subscriptions

initFrameRouter :: FrameHandler -> IO Notifier
initFrameRouter handler = do
    updateChannel <- sync newSChan
    frameChannel  <- sync newSChan
    notifier      <- return $ Notifier updateChannel
    subscriptions <- return $ Subscriptions HM.empty
    frameRouter   <- return $ FrameRouter frameChannel updateChannel [] subscriptions
    forkIO $ frameLoop frameChannel handler
    forkIO $ routerLoop frameRouter
    return notifier

frameLoop :: SChan Update -> FrameHandler -> IO ()
frameLoop frameChannel handler = do
    f <- get handler
    case f of 
        NewFrame frame -> do
            sync $ sendEvt frameChannel (GotFrame frame)
            frameLoop frameChannel handler
        GotEof -> do
            sync $ sendEvt frameChannel ServerDisconnected
            return ()

routerLoop :: FrameRouter -> IO ()
routerLoop router@(FrameRouter frameChannel updateChannel _ _) = do
    update      <- sync $ chooseEvt (recvEvt frameChannel) (recvEvt updateChannel)
    maybeRouter <- handleUpdate update router
    case maybeRouter of
        Just router' -> routerLoop router'
        Nothing      -> return ()

handleUpdate :: Update -> FrameRouter -> IO (Maybe FrameRouter)
handleUpdate update router@(FrameRouter _ _ responseChannels subscriptions) = 
    case update of
        GotFrame frame -> do
            handleFrame frame responseChannels subscriptions
            return $ Just router
        ResponseRequest responseChannel -> 
            return $ Just $ addResponseChannel router responseChannel
        SubscriptionRequest subId subChannel ->
            return $ Just $ addSubscriptionChannel router subId subChannel
        ServerDisconnected -> do
            handleDisconnect responseChannels subscriptions
            return Nothing

addResponseChannel :: FrameRouter -> (SChan FrameEvt) -> FrameRouter
addResponseChannel (FrameRouter f u r s) newChan =
    FrameRouter f u  (newChan:r) s

addSubscriptionChannel :: FrameRouter -> String -> (SChan FrameEvt) -> FrameRouter
addSubscriptionChannel router@(FrameRouter f u r (Subscriptions subs)) subId newChan = 
    let sub = HM.lookup subId subs in
        case sub of 
            Just subscriptionChannels ->
                FrameRouter f u r (Subscriptions (HM.insert  subId (newChan:subscriptionChannels) subs))
            Nothing ->
                FrameRouter f u r (Subscriptions (HM.insert subId [newChan] subs))

handleFrame :: Frame -> [SChan FrameEvt] -> Subscriptions -> IO ()
handleFrame frame responseChannels subscriptions = 
    let channels = selectChannels (getCommand frame) (getHeaders frame) responseChannels subscriptions in
        sendFrame frame channels

selectChannels :: Command -> Headers -> [SChan FrameEvt] -> Subscriptions -> [SChan FrameEvt]
selectChannels MESSAGE headers _ (Subscriptions subs) = case (getValueForHeader "subscription" headers) of
    Just subId -> case HM.lookup subId subs of
        Just channels -> channels
        Nothing       -> []  
    Nothing -> []
selectChannels _ _ responseChannels _ = responseChannels

sendFrame :: Frame -> [SChan FrameEvt] -> IO ()
sendFrame frame []          = return ()
sendFrame frame (chan:rest) = do
    forkIO $ sync (sendEvt chan (NewFrame frame))
    sendFrame frame rest

handleDisconnect :: [SChan FrameEvt] -> Subscriptions -> IO ()
handleDisconnect responseChannels (Subscriptions subs) = 
    let allListeners = responseChannels ++ (concat $ HM.elems subs) in
        sendDisconnect allListeners

sendDisconnect :: [SChan FrameEvt] -> IO ()
sendDisconnect [] = return ()
sendDisconnect (chan:chans) = do
    forkIO $ sync (sendEvt chan GotEof)
    sendDisconnect chans

requestResponseEvents :: Notifier -> IO (SChan FrameEvt)
requestResponseEvents (Notifier chan) = do
    frameChannel <- sync newSChan
    sync $ sendEvt chan (ResponseRequest frameChannel)
    return frameChannel

requestSubscriptionEvents :: Notifier -> String -> IO (SChan FrameEvt)
requestSubscriptionEvents (Notifier chan) subscriptionId = do
    frameChannel <- sync newSChan
    sync $ sendEvt chan (SubscriptionRequest subscriptionId frameChannel)
    return frameChannel
