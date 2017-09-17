data Header         =   Header HeaderName HeaderValue
type Headers        =   [Header]
type HeaderName     =   String
type HeaderValue    =   String

type Body           =   String

data ClientCommand  =   SEND |
                        SUBSCRIBE |
                        UNSUBSCRIBE |
                        BEGIN |
                        COMMIT |
                        ABORT |
                        ACK |
                        NACK |
                        DISCONNECT |
                        CONNECT |
                        STOMP deriving Show

data ServerCommand  =   CONNECTED |
                        MESSAGE |
                        RECEIPT |
                        ERROR deriving Show

data Command        =   S ServerCommand | C ClientCommand

type Frame          =   (Command, Maybe Headers, Maybe Body)

connectHeaders :: Headers
connectHeaders = [Header "accept-version" "1.2", Header "host" "wickstopher.com"]

makeConnect :: Frame
makeConnect = (C CONNECT, Just connectHeaders, Nothing)

