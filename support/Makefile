# Builds the libcurl shim the Idris code calls into.
#
#   make         build the shared library and copy it to ../lib, which Idris
#                installs with the package and searches for foreign libraries
#   make clean

NAME   = libidris2_openrouter
CC     ?= cc

UNAME := $(shell uname -s)
ifeq ($(UNAME),Darwin)
  EXT = dylib
else ifeq ($(OS),Windows_NT)
  EXT = dll
else
  EXT = so
endif

TARGET = $(NAME).$(EXT)

CURL_CFLAGS := $(shell curl-config --cflags 2>/dev/null)
CURL_LIBS   := $(shell curl-config --libs 2>/dev/null || echo -lcurl)

CFLAGS  += -O2 -fPIC -Wall -Wextra $(CURL_CFLAGS)
LDFLAGS += -shared

LIBDIR = ../lib

.PHONY: all clean

all: $(LIBDIR)/$(TARGET)

$(TARGET): openrouter_curl.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< $(CURL_LIBS)

$(LIBDIR)/$(TARGET): $(TARGET)
	mkdir -p $(LIBDIR)
	cp $(TARGET) $(LIBDIR)/

clean:
	rm -f $(TARGET) $(LIBDIR)/$(TARGET)
