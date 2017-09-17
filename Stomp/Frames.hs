module Stomp.Frames where

import Data.ByteString.UTF8 as UTF

data Header         =   Header HeaderName HeaderValue
data Headers        =   Some Header Headers | EndOfHeaders
type HeaderName     =   String
type HeaderValue    =   String

data Body           =   EmptyBody | Body ByteString

data Command        =   SEND |
                        SUBSCRIBE |
                        UNSUBSCRIBE |
                        BEGIN |
                        COMMIT |
                        ABORT |
                        ACK |
                        NACK |
                        DISCONNECT |
                        CONNECT |
                        STOMP |
                        CONNECTED |
                        MESSAGE |
                        RECEIPT |
                        ERROR deriving Show

data Frame          =   Frame Command Headers Body

instance Show Header where
    show (Header headerName headerValue) = headerName ++ ":" ++ headerValue

instance Show Headers where
    show EndOfHeaders = "\n"
    show (Some header headers) = show header ++ "\n" ++ show headers

instance Show Body where
    show EmptyBody = ""
    show (Body s)    = show s

instance Show Frame where
    show (Frame c h b) = show c ++ "\n" ++ show h ++ show b ++ "\NUL"


-- Header utility functions

makeHeaders :: [Header] -> Headers
makeHeaders []     = EndOfHeaders
makeHeaders (x:xs) = Some x (makeHeaders xs)

addHeaderEnd :: Header -> Headers -> Headers
addHeaderEnd newHeader EndOfHeaders = Some newHeader EndOfHeaders
addHeaderEnd newHeader (Some h hs)  = Some h (addHeaderEnd newHeader hs)

addHeaderFront :: Header -> Headers -> Headers
addHeaderFront newHeader EndOfHeaders = Some newHeader EndOfHeaders
addHeaderFront newHeader (Some h hs)  = Some newHeader (addHeaderFront h hs)

addFrameHeaderEnd :: Header -> Frame -> Frame
addFrameHeaderEnd header (Frame c h b) = Frame c (addHeaderEnd header h) b

addFrameHeaderFront :: Header -> Frame -> Frame
addFrameHeaderFront header (Frame c h b) = Frame c (addHeaderFront header h) b

addHeaders :: Headers -> Headers -> Headers
addHeaders headers EndOfHeaders = headers
addHeaders headers (Some h hs)  = (Some h (addHeaders headers hs))

-- Frame utility functions

textFrame :: String -> Command -> Frame
textFrame message command = let encoding = (UTF.fromString message) in
    Frame command 
          (makeHeaders [
            plainTextContentHeader,
            contentLengthHeader encoding
            ]
          )
          (Body encoding)


-- Convenience functions to create various concrete headers

stompHeaders ::  String -> Headers
stompHeaders host = makeHeaders [Header "accept-version" "1.2", Header "host" host]

versionHeader :: Header
versionHeader = Header "version" "1.2"

plainTextContentHeader :: Header
plainTextContentHeader = Header "content-type" "text/plain"

contentLengthHeader :: ByteString -> Header
contentLengthHeader s = Header "content-length" (show $ UTF.length s)

destinationHeader :: String -> Header
destinationHeader s = Header "destination" s


-- Client frames

stomp :: String -> Frame
stomp host = Frame STOMP (stompHeaders host) EmptyBody

connect :: String -> Frame
connect host = Frame CONNECT (stompHeaders host) EmptyBody

-- Server frames

connected :: Frame
connected = Frame CONNECTED (makeHeaders [versionHeader]) EmptyBody

errorFrame :: String -> Frame
errorFrame message = textFrame message ERROR

sendText :: String -> String -> Frame
sendText message dest = 
    addFrameHeaderFront (destinationHeader dest) (textFrame message SEND)