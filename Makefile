# ===== Local / CI 通用 Makefile（可在 GitHub Actions 或本地工具链使用） =====
# 如果在本地编译：把 TOOLCHAIN / SDK_PATH 改成你自己的路径
TOOLCHAIN ?= $(PWD)/toolchain/usr
SDK_PATH  ?= $(PWD)
SDK       ?= iPhoneOS14.5.sdk
ARCH      ?= arm64
MIN_IOS   ?= 12.0

CC       := $(TOOLCHAIN)/bin/clang
SYSROOT  := $(SDK_PATH)/$(SDK)
CFLAGS   := -fobjc-arc -ObjC -isysroot $(SYSROOT) -arch $(ARCH) -miphoneos-version-min=$(MIN_IOS)
LDFLAGS  := -dynamiclib
FW       := -framework Foundation -framework UIKit -framework AVFoundation

all: KnPatch.dylib

KnPatch.dylib: KnPatch.m
	$(CC) $(LDFLAGS) $(CFLAGS) $(FW) $< -o $@

clean:
	rm -f KnPatch.dylib
