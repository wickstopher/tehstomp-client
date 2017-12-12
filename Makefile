FLAGS=-threaded +RTS -N4

build:
	ghc StompClient $(FLAGS)
	ghc Producer $(FLAGS)
	ghc Consumer $(FLAGS)
	ghc HeartBeatGood $(FLAGS)
	ghc HeartBeatBadClient $(FLAGS)
	ghc HeartBeatServerTimeout $(FLAGS)

clean:
	rm -f StompClient Producer Consumer HeartBeatGood HeartBeatServerTimeout HeartBeatBadClient *.o *.hi
