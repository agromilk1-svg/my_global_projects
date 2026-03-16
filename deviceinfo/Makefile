TARGET = deviceinfo
ARCHS = arm64
SDK = iphoneos

CC = xcrun -sdk $(SDK) clang
LD = xcrun -sdk $(SDK) clang
STRIP = xcrun -sdk $(SDK) strip
CODESIGN = ldid -S

CFLAGS = -arch $(ARCHS) -fobjc-arc -I.
LDFLAGS = -arch $(ARCHS) -framework UIKit -framework Foundation -framework CoreGraphics

SOURCES = main.m AppDelegate.m ViewController.m DeviceInfoLogic.m

all: $(TARGET).app

$(TARGET).app: $(TARGET)
	mkdir -p $@
	cp $(TARGET) $@/
	cp Info.plist $@/
	@echo "Built $(TARGET).app"

$(TARGET): $(SOURCES)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

clean:
	rm -rf $(TARGET) $(TARGET).app

.PHONY: all clean
