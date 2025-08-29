# === KnPatch / minimal clang Makefile (use THEOS toolchain) ===

# CI/本地都要能工作：如果外部没导出 THEOS，就默认放到当前仓库下的 theos
THEOS ?= $(CURDIR)/theos

SDK    := $(THEOS)/sdks/iPhoneOS14.5.sdk
CLANG  := $(THEOS)/toolchain/usr/bin/clang

# 你的最小系统版本（不影响能否在 14.4 上运行，通常 12.0 就行）
MINVER := 12.0

CFLAGS := -fobjc-arc -O2 -isysroot $(SDK) -arch arm64 -miphoneos-version-min=$(MINVER)
LDFLAGS := -framework Foundation -framework UIKit -framework AVFoundation

all: KnPatch.dylib

KnPatch.dylib: KnPatch.m
	$(CLANG) -dynamiclib $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f KnPatch.dylib
