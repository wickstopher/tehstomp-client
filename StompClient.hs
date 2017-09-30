import Network as Network
import System.IO
import Data.ByteString
import Stomp.Frames

main :: IO ()
main = do
    handle <- Network.connectTo "localhost" (PortNumber 2323)
    hPut handle (frameToBytes (connect "hi"))
    hClose handle
