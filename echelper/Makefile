export THEOS_DEVICE_IP = 
export MODULES = 0
export _THEOS_TARGET_MODULES_SUPPORT := 0
export _THEOS_DARWIN_CAN_USE_MODULES := $(_THEOS_FALSE)
export EMBEDDED_ROOT_HELPER := 1
export FINALPACKAGE := 1

TARGET := iphone:clang:14.5:14.0
INSTALL_TARGET_PROCESSES = ECHelper

ARCHS = arm64

# Skip signing in Theos (ldid broken), will sign manually later
TARGET_CODESIGN = echo

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = ECHelper

ECHelper_FILES = $(wildcard *.m) $(wildcard *.c)
ECHelper_FRAMEWORKS = CoreGraphics CoreServices CoreTelephony Security
ECHelper_PRIVATE_FRAMEWORKS = Preferences MobileContainerManager SpringBoardServices BackBoardServices FrontBoardServices
ECHelper_CFLAGS = -fobjc-arc -fno-modules -fno-autolink -I. -I../PrivateHeaders -I$(THEOS)/vendor/include -Wno-error=availability -Wno-availability -F. -DEMBEDDED_ROOT_HELPER=1
ADDITIONAL_OBJCCFLAGS = -fno-modules -fno-autolink
ADDITIONAL_CFLAGS = -fno-modules -fno-autolink
ECHelper_LDFLAGS = -F. -lc++ -L$(THEOS)/lib -fno-modules -fno-autolink -framework Foundation -framework UIKit
ECHelper_LIBRARIES = archive

ECHelper_CODESIGN_FLAGS = --entitlements entitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
