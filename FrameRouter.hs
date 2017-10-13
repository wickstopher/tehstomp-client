module FrameRouter (
    initFrameRouter,
    requestResponseEvents,
    requestSubscriptionEvents,
    Notifier,
    ResponseChannel
) where

import Control.Concurrent
import Control.Concurrent.TxEvent
import Data.HashMap.Strict as HM
import Stomp.Frames
import Stomp.Frames.IO

type ResponseChannel     = SChan Frame
type SubscriptionChannel = SChan Frame

data Update        = ResponseRequest ResponseChannel  | 
                     SubscriptionRequest String SubscriptionChannel |
                     GotFrame Frame

data Notifier      = Notifier (SChan Update)

data Subscriptions = Subscriptions (HashMap String [SubscriptionChannel])

data FrameRouter   = FrameRouter (SChan Update) (SChan Update) [ResponseChannel] Subscriptions

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
    frame <- get handler
    sync $ sendEvt frameChannel (GotFrame frame)
    frameLoop frameChannel handler

routerLoop :: FrameRouter -> IO ()
routerLoop router@(FrameRouter frameChannel updateChannel _ _) = do
    update      <- sync $ chooseEvt (recvEvt frameChannel) (recvEvt updateChannel)
    router'     <- handleUpdate update router
    routerLoop router'

handleUpdate :: Update -> FrameRouter -> IO FrameRouter
handleUpdate update router@(FrameRouter _ _ responseChannels subscriptions) = 
    case update of
        GotFrame frame -> do
            handleFrame frame responseChannels subscriptions
            return router
        ResponseRequest responseChannel -> 
            return $ addResponseChannel router responseChannel
        SubscriptionRequest subId subChannel ->
            return $ addSubscriptionChannel router subId subChannel

addResponseChannel :: FrameRouter -> ResponseChannel -> FrameRouter
addResponseChannel (FrameRouter f u r s) newChan =
    FrameRouter f u  (newChan:r) s

addSubscriptionChannel :: FrameRouter -> String -> SubscriptionChannel -> FrameRouter
addSubscriptionChannel router@(FrameRouter f u r (Subscriptions subs)) subId newChan = 
    let sub = HM.lookup subId subs in
        case sub of 
            Just subscriptionChannels ->
                FrameRouter f u r (Subscriptions (HM.insert  subId (newChan:subscriptionChannels) subs))
            Nothing -> router

handleFrame :: Frame -> [ResponseChannel] -> Subscriptions -> IO ()
handleFrame frame responseChannels subscriptions = 
    let channels = selectChannels (getCommand frame) (getHeaders frame) responseChannels subscriptions in
        sendFrame frame channels

selectChannels :: Command -> Headers -> [ResponseChannel] -> Subscriptions -> [SChan Frame]
selectChannels MESSAGE headers _ (Subscriptions subs) = case (getValueForHeader "subscription" headers) of
    Just subId -> case HM.lookup subId subs of
        Just channels -> channels
        Nothing       -> []  
    Nothing -> []
selectChannels _ _ responseChannels _ = responseChannels

sendFrame :: Frame -> [SChan Frame] -> IO ()
sendFrame frame []          = return ()
sendFrame frame (chan:rest) = do
    forkIO $ sync (sendEvt chan frame)
    sendFrame frame rest

requestResponseEvents :: Notifier -> IO ResponseChannel
requestResponseEvents (Notifier chan) = do
    frameChannel <- sync newSChan
    sync $ sendEvt chan (ResponseRequest frameChannel)
    return frameChannel

requestSubscriptionEvents :: Notifier -> String -> IO SubscriptionChannel
requestSubscriptionEvents (Notifier chan) subscriptionId = do
    frameChannel <- sync newSChan
    sync $ sendEvt chan (SubscriptionRequest subscriptionId frameChannel)
    return frameChannel
