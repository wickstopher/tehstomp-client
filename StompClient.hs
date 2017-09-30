import Network as Network
import System.IO
import Data.ByteString
import Stomp.Frames

main :: IO ()
main = do
    handle <- Network.connectTo "localhost" (PortNumber 2323)
    hPut handle (frameToBytes (connect "hi"))
    hPut handle (frameToBytes (sendText "hi" "someq"))
    hPut handle (frameToBytes (sendText "bye" "someq"))
    hPut handle (frameToBytes (disconnect "buhuug"))
    hClose handle

sendFrames :: [Frame] -> IO ()
sendFrames frames = do
    handle <- Network.connectTo "localhost" (PortNumber 2323)
    processFrames handle frames
    hClose handle

processFrames :: Handle -> [Frame] -> IO ()
processFrames handle [] = return ()
processFrames handle (frame:frames) = do
    hPut handle (frameToBytes frame)
    processFrames handle frames