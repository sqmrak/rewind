# host tests stay independent from UIKit and the ios toolchain

CC ?= cc
CFLAGS ?= -std=c99 -Wall -Wextra -O2 -I../core

.PHONY: all test clean

all: test

test: test_model test_qr test_fmp4 test_ump test_audio test_sabr test_playback test_layout
	./test_model
	./test_qr
	./test_fmp4
	./test_ump
	./test_audio
	./test_sabr
	./test_playback
	./test_layout
	python3 test_network.py
	python3 test_account.py

test_layout: test_layout.c ../core/rewind_layout.c ../core/rewind_layout.h
	$(CC) $(CFLAGS) test_layout.c ../core/rewind_layout.c -lm -o $@

test_model: test_model.c ../core/rewind_model.c ../core/rewind_model.h
	$(CC) $(CFLAGS) test_model.c ../core/rewind_model.c -o $@

test_qr: test_qr.c ../core/rewind_qr.c ../core/rewind_qr.h
	$(CC) $(CFLAGS) test_qr.c ../core/rewind_qr.c -o $@

test_fmp4: test_fmp4.c ../core/rewind_fmp4.c ../core/rewind_fmp4.h
	$(CC) $(CFLAGS) test_fmp4.c ../core/rewind_fmp4.c -o $@

test_ump: test_ump.c ../core/rewind_ump.c ../core/rewind_ump.h
	$(CC) $(CFLAGS) test_ump.c ../core/rewind_ump.c -o $@

test_audio: test_audio.c ../core/rewind_audio.c ../core/rewind_audio.h
	$(CC) $(CFLAGS) test_audio.c ../core/rewind_audio.c -o $@

test_sabr: test_sabr.c ../core/rewind_sabr.c ../core/rewind_sabr.h ../core/rewind_fmp4.c ../core/rewind_fmp4.h ../core/rewind_ump.c ../core/rewind_ump.h
	$(CC) $(CFLAGS) test_sabr.c ../core/rewind_sabr.c ../core/rewind_fmp4.c ../core/rewind_ump.c -o $@

test_playback: test_playback.c ../core/rewind_playback.c ../core/rewind_playback.h
	$(CC) $(CFLAGS) test_playback.c ../core/rewind_playback.c -o $@

clean:
	rm -f test_model test_qr test_fmp4 test_ump test_audio test_sabr test_playback test_layout
