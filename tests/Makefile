# host tests stay independent from UIKit and the ios toolchain

CC ?= cc
CFLAGS ?= -std=c99 -Wall -Wextra -O2 -I../core

.PHONY: all test clean

all: test

test: test_model
	./test_model

test_model: test_model.c ../core/tunetube_model.c ../core/tunetube_model.h
	$(CC) $(CFLAGS) test_model.c ../core/tunetube_model.c -o $@

clean:
	rm -f test_model
