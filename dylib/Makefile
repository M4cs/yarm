# Builds libyarm.dylib for arm64 macOS.
#
# DYLD will refuse to inject an unsigned dylib into many processes even with
# SIP off, so we ad-hoc sign it. That's enough on a SIP-disabled machine; it
# is NOT enough to inject into hardened/Apple-signed binaries with library
# validation on — that's a separate (and intentionally hostile-to-circumvent)
# constraint, addressed in the README under "Library validation."

DYLIB    := libyarm.dylib
SRC      := yarm_inject.m yarm_swizzle.m yarm_interpose.c
SDK      := $(shell xcrun --sdk macosx --show-sdk-path)
MIN_OS   := 14.0

# Universal binary: arm64 for third-party apps, arm64e for Apple's own
# (Finder, Safari, Mail, every /usr/bin tool on Apple Silicon). dyld refuses
# to load an arm64-only dylib into an arm64e host even with AMFI off, so both
# slices are required for the system-wide inject story.
ARCHES   := -arch arm64 -arch arm64e
CFLAGS   := $(ARCHES) -isysroot $(SDK) -mmacosx-version-min=$(MIN_OS) \
            -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
            -fvisibility=hidden
LDFLAGS  := -dynamiclib \
            -framework Foundation -framework Cocoa -framework QuartzCore \
            -framework CoreGraphics \
            -F/System/Library/PrivateFrameworks -weak_framework SkyLight \
            -install_name @rpath/$(DYLIB)

all: $(DYLIB)

$(DYLIB): $(SRC)
	clang $(CFLAGS) $(LDFLAGS) -o $@ $(SRC)
	codesign -s - -f $@

clean:
	rm -f $(DYLIB)

.PHONY: all clean
