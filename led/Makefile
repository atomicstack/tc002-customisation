# tc002 led tools: a native popsquares binary for the panel, plus host-side unit tests.
#
#   make          cross-build ./popsquares for the device (static armv7 musl, via zig cc)
#   make test     build and run the host tests with the same zig cc
#   make clean
#
# only zig is required (brew install zig); it bundles clang, musl and the linux headers.

ZIG    ?= zig
TARGET ?= arm-linux-musleabihf
MCPU   ?= cortex_a7
CFLAGS ?= -O2 -std=c11 -Wall -Wextra -Wno-unused-parameter

CROSS_CC = $(ZIG) cc -target $(TARGET) -mcpu=$(MCPU)
HOST_CC  = $(ZIG) cc

SRC = main.c led_frame.c led_dev.c popsquares.c
HDR = led.h popsquares.h

all: popsquares

popsquares: $(SRC) $(HDR)
	$(CROSS_CC) $(CFLAGS) -static -s -o $@ $(SRC)

test: test_led test_popsquares
	./test_led
	./test_popsquares

test_led: test_led.c led_frame.c led.h check.h
	$(HOST_CC) $(CFLAGS) -o $@ test_led.c led_frame.c

test_popsquares: test_popsquares.c popsquares.c popsquares.h led.h check.h
	$(HOST_CC) $(CFLAGS) -o $@ test_popsquares.c popsquares.c

clean:
	rm -f popsquares test_led test_popsquares
	rm -rf .zig-cache

.PHONY: all test clean
