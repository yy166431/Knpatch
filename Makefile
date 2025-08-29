# === KnPatch / minimal clang Makefile (use THEOS toolchain) ===

THEOS ?= $(CURDIR)/theos

SDK    := $(THEOS)/sdks/iPhoneOS14.5.sdk
CLANG  := $(THEOS)/toolchain/usr/bin/clang

MINVER := 12.0

CFLAGS  := -fobjc-arc -O2 -isysroot $(SDK) -arch arm64 -miphoneos-version-min=$(MINVER)
LDFLAGS := -framework Foundation -framework UIKit -framework AVFoundation

all: KnPatch.dylib

KnPatch.dylib: KnPatch.m
	$(CLANG) -dynamiclib $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f KnPatch.dylib
