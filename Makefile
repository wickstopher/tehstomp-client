FLAGS=-threaded +RTS -N4

build:
	ghc StompClient $(FLAGS)
	ghc Producer $(FLAGS)
	ghc Consumer $(FLAGS)

clean:
	rm -f StompClient Producer Consumer *.o *.hi
