# ===== User config =====
SDK            ?= iPhoneOS14.5.sdk
MIN_IOS        ?= 12.0
ARCH           ?= arm64

# ===== Auto paths =====
# 这三个环境变量由 GitHub Actions 传进来；本地没有也能用默认值
SDK_PATH       ?= $(PWD)/iOS_SDK
TOOLCHAIN_ROOT ?= $(PWD)/toolchain/usr
CLANG          := $(TOOLCHAIN_ROOT)/bin/clang

CFLAGS  := -isysroot $(SDK_PATH)/$(SDK) -arch $(ARCH) -miphoneos-version-min=$(MIN_IOS) -fobjc-arc -O2
LDFLAGS := -dynamiclib -fobjc-arc
FW      := -framework Foundation -framework UIKit -framework AVFoundation

all: KnPatch.dylib

KnPatch.dylib: KnPatch.m
	$(CLANG) $(LDFLAGS) $(CFLAGS) $(FW) -o $@ $<

clean:
	rm -f KnPatch.dylib
