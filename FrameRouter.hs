module FrameRouter where

import Control.Concurrent
import Control.Concurrent.TxEvent
import Data.HashMap.Strict as HM
import Stomp.Frames
import Stomp.Frames.IO

type ResponseChannel     = SChan Frame
type SubscriptionChannel = SChan Frame

data Update        = ResponseRequest ResponseChannel  | 
                     SubscriptionRequest SubscriptionChannel |
                     NoUpdate

data Notifier      = Notifier (SChan Update)

data Subscriptions = Subscriptions (HashMap String [SubscriptionChannel])

data FrameRouter   = FrameRouter (SChan (Maybe Frame)) (SChan Update) [ResponseChannel] Subscriptions


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

frameLoop :: SChan (Maybe Frame) -> FrameHandler -> IO ()
frameLoop frameChannel handler = do
    frame <- get handler
    sync $ sendEvt frameChannel (Just frame)
    frameLoop frameChannel handler

routerLoop :: FrameRouter -> IO ()
routerLoop r@(FrameRouter frameChannel updateChannel responseChannels subscriptions) = do
    notification <- sync $ chooseEvt (alwaysEvt NoUpdate) (recvEvt updateChannel)
    frame        <- sync $ chooseEvt (alwaysEvt Nothing)  (recvEvt frameChannel)
    routerLoop r

handleFrame :: Frame -> [ResponseChannel] -> Subscriptions -> IO ()
handleFrame frame responseChannels subscriptions = 
    let channels = selectChannels (getCommand frame) (getHeaders frame) responseChannels subscriptions in
        sendFrame frame channels

selectChannels :: Command -> Headers -> [ResponseChannel] -> Subscriptions -> [SChan Frame]
selectChannels MESSAGE _ _ subscriptions = [] -- TODO find sub based on subID and send the frame to all listeners for tha tsub
selectChannels _ _ responseChannels _ = responseChannels

sendFrame :: Frame -> [SChan Frame] -> IO ()
sendFrame frame []          = return ()
sendFrame frame (chan:rest) = do
    forkIO $ sync (sendEvt chan frame)
    sendFrame frame rest
