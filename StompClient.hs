import Network as Network
import System.IO
import Stomp.Frames

main :: IO ()
main = do
    handle <- Network.connectTo "localhost" (PortNumber 2323)
    hPutStr handle (show (connect "hi"))
    hClose handle
