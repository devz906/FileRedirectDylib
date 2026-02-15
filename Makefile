# FileRedirectDylib Makefile
#
# Build a dylib for iOS arm64 using Xcode's clang.
# Requires macOS with Xcode (or Xcode Command Line Tools) + iOS SDK.
#
# Usage:
#   make            — build FileRedirect.dylib
#   make clean      — remove build artifacts
#
# If your iOS SDK path differs, override it:
#   make SDK=/path/to/iPhoneOS.sdk

# --- Configuration ---
CC       = xcrun -sdk iphoneos clang
SDK     ?= $(shell xcrun --sdk iphoneos --show-sdk-path)
ARCH     = arm64
MIN_IOS  = 12.0

TARGET   = FileRedirect.dylib
SOURCES  = tweak.m fishhook.c
OBJECTS  = tweak.o fishhook.o

CFLAGS   = -arch $(ARCH) \
           -isysroot $(SDK) \
           -miphoneos-version-min=$(MIN_IOS) \
           -fobjc-arc \
           -fmodules \
           -Wall

LDFLAGS  = -arch $(ARCH) \
           -isysroot $(SDK) \
           -miphoneos-version-min=$(MIN_IOS) \
           -dynamiclib \
           -framework Foundation \
           -install_name @executable_path/$(TARGET)

# --- Targets ---

all: $(TARGET)

$(TARGET): $(OBJECTS)
	$(CC) $(LDFLAGS) -o $@ $^
	@echo "✅ Built $(TARGET) for iOS $(ARCH)"

tweak.o: tweak.m fishhook.h
	$(CC) $(CFLAGS) -c tweak.m -o tweak.o

fishhook.o: fishhook.c fishhook.h
	$(CC) $(CFLAGS) -c fishhook.c -o fishhook.o

clean:
	rm -f $(OBJECTS) $(TARGET)
	@echo "🧹 Cleaned build artifacts"

.PHONY: all clean
