#
# libswiftCompatibilityEC.dylib Makefile
# 设备信息伪装动态库编译脚本
#

SDK = $(shell xcrun --sdk iphoneos --show-sdk-path)
CC = xcrun -sdk iphoneos clang
ARCH = arm64
MIN_IOS = 14.0
DYLIB_NAME = libswiftCompatibilityEC.dylib

SOURCES = \
	ECDeviceSpoof.m \
	SCPrefLoader.m \
	fishhook.c

CFLAGS = \
	-target $(ARCH)-apple-ios$(MIN_IOS) \
	-isysroot $(SDK) \
	-fobjc-arc \
	-O2 \
	-dynamiclib \
	-install_name @executable_path/Frameworks/$(DYLIB_NAME)

FRAMEWORKS = \
	-framework Foundation \
	-framework UIKit \
	-framework CoreTelephony \
	-framework AdSupport \
	-framework Security \
	-framework SystemConfiguration \
	-framework MobileCoreServices \
	-framework CoreServices

LDFLAGS = \
	-Wl,-dead_strip \
	-undefined dynamic_lookup

.PHONY: all clean

all: $(DYLIB_NAME)

$(DYLIB_NAME): $(SOURCES)
	@echo "[+] Building $(DYLIB_NAME)..."
	$(CC) $(CFLAGS) $(SOURCES) $(FRAMEWORKS) $(LDFLAGS) -o $(DYLIB_NAME)
	@echo "[+] Built: $(DYLIB_NAME)"
	@ls -la $(DYLIB_NAME)

clean:
	rm -f $(DYLIB_NAME)
	@echo "[-] Cleaned."
