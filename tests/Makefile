# host tests stay independent from UIKit and the ios toolchain

CC ?= cc
CFLAGS ?= -std=c99 -Wall -Wextra -O2 -I../core

.PHONY: all test clean

all: test

test: test_model test_qr test_fmp4 test_ump test_audio test_sabr test_playback test_layout test_motion test_emoji test_text_class test_device test_link
	./test_model
	./test_qr
	./test_fmp4
	./test_ump
	./test_audio
	./test_sabr
	./test_playback
	./test_layout
	./test_motion
	./test_emoji
	./test_text_class
	./test_device
	./test_link
	python3 test_network.py
	python3 test_account.py

test_emoji: test_emoji.c test_util.h ../core/rewind_emoji.c ../core/rewind_emoji_data.c ../core/rewind_emoji.h
	$(CC) $(CFLAGS) test_emoji.c ../core/rewind_emoji.c ../core/rewind_emoji_data.c -lm -o $@

test_link: test_link.c ../core/rewind_link.c ../core/rewind_link.h
	$(CC) $(CFLAGS) test_link.c ../core/rewind_link.c -o $@

test_device: test_device.c ../core/rewind_device.c ../core/rewind_device.h
	$(CC) $(CFLAGS) test_device.c ../core/rewind_device.c -o $@

test_text_class: test_text_class.c test_util.h ../core/rewind_text_class.c ../core/rewind_text_class.h
	$(CC) $(CFLAGS) test_text_class.c ../core/rewind_text_class.c -o $@

test_motion: test_motion.c ../core/rewind_motion.c ../core/rewind_motion.h
	$(CC) $(CFLAGS) test_motion.c ../core/rewind_motion.c -lm -o $@

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
