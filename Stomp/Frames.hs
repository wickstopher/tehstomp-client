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


makeHeaders :: [Header] -> Headers
makeHeaders []     = EndOfHeaders
makeHeaders (x:xs) = Some x (makeHeaders xs)

-- Convenience functions to create various headers

stompHeaders ::  String -> Headers
stompHeaders host = makeHeaders [Header "accept-version" "1.2", Header "host" host]

versionHeader :: Header
versionHeader = Header "version" "1.2"

plainTextContentHeader :: Header
plainTextContentHeader = Header "content-type" "text/plain"

contentLengthHeader :: ByteString -> Header
contentLengthHeader s = Header "content-length" (show $ UTF.length s)


-- Client frames

stomp :: String -> Frame
stomp host = Frame STOMP (stompHeaders host) EmptyBody

connect :: String -> Frame
connect host = Frame CONNECT (stompHeaders host) EmptyBody

-- Server frames

connected :: Frame
connected = Frame CONNECTED (makeHeaders [versionHeader]) EmptyBody

errorFrame :: String -> Frame
errorFrame message = let encoding = (UTF.fromString message) in 
    Frame  ERROR  
          (makeHeaders [
            versionHeader, 
            plainTextContentHeader, 
            contentLengthHeader encoding
            ]
          ) 
          (Body encoding)
