CC      = gcc
CFLAGS  = -O2 -pthread -Wall -Wextra -std=c11
LDFLAGS = -pthread

BINS = chat_server chat_client

.PHONY: all clean

all: $(BINS)

%: %.c
	$(CC) $(CFLAGS) $< -o $@ $(LDFLAGS)

clean:
	rm -f $(BINS)
