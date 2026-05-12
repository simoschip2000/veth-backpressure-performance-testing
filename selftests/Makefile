# SPDX-License-Identifier: GPL-2.0
TARGETS := udp_flood udp_sink
CFLAGS  ?= -O2 -Wall
udp_sink: LDLIBS := -lm

.PHONY: all clean
all: $(TARGETS)
clean:
	rm -f $(TARGETS)
