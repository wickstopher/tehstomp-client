data Header         =   Header HeaderName HeaderValue
data Headers        =   Some Header Headers | EndOfHeaders
type HeaderName     =   String
type HeaderValue    =   String

data Body           =   EmptyBody | Body String

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
    show EndOfHeaders = ""
    show (Some header headers) = show header ++ "\n" ++ show headers

instance Show Body where
    show EmptyBody = ""
    show (Body s)    = s

instance Show Frame where
    show (Frame c h b) = show c ++ "\n" ++ show h ++ show b ++ "\NUL"


listToHeaders :: [Header] -> Headers
listToHeaders []     = EndOfHeaders
listToHeaders (x:xs) = Some x (listToHeaders xs)

connectHeaders :: Headers
connectHeaders = listToHeaders [Header "accept-version" "1.2", Header "host" "wickstopher.com"]

makeConnect :: Frame
makeConnect = Frame CONNECT connectHeaders EmptyBody
