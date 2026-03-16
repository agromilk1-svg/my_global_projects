/**
 * Copyright (c) 2018-present, Facebook, Inc.
 * All rights reserved.
 *
 * FBTouchMonitor - Implementation of touch event monitoring
 */

#import "FBTouchMonitor.h"
#import <XCTest/XCTest.h>
#import <dlfcn.h>

// IOHIDEvent private API declarations
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef double IOHIDFloat;

// Event types
enum {
  kIOHIDEventTypeNULL = 0,
  kIOHIDEventTypeDigitizer = 11,
};

// Digitizer event masks
enum {
  kIOHIDDigitizerEventRange = 1 << 0,
  kIOHIDDigitizerEventTouch = 1 << 1,
  kIOHIDDigitizerEventPosition = 1 << 2,
};

// Function pointers for dynamic loading
static IOHIDEventSystemClientRef (*_IOHIDEventSystemClientCreate)(
    CFAllocatorRef allocator);
static void (*_IOHIDEventSystemClientScheduleWithRunLoop)(
    IOHIDEventSystemClientRef client, CFRunLoopRef runLoop, CFStringRef mode);
static void (*_IOHIDEventSystemClientUnscheduleFromRunLoop)(
    IOHIDEventSystemClientRef client, CFRunLoopRef runLoop, CFStringRef mode);
static void (*_IOHIDEventSystemClientRegisterEventCallback)(
    IOHIDEventSystemClientRef client, void *callback, void *target,
    void *refcon);
static uint32_t (*_IOHIDEventGetType)(IOHIDEventRef event);
static IOHIDFloat (*_IOHIDEventGetFloatValue)(IOHIDEventRef event,
                                              uint32_t field);
static CFIndex (*_IOHIDEventGetIntegerValue)(IOHIDEventRef event,
                                             uint32_t field);

// Field constants
#define IOHIDEventFieldDigitizerX 0xB0001
#define IOHIDEventFieldDigitizerY 0xB0002
#define IOHIDEventFieldDigitizerEventMask 0xB000B

#define kMaxTouchEvents 100

// Default screen dimensions - can be updated via API
static CGFloat _monitorScreenWidth = 375.0;
static CGFloat _monitorScreenHeight = 812.0;

#pragma mark - FBTouchEvent

@implementation FBTouchEvent

- (NSDictionary *)toDictionary {
  NSString *typeStr = @"unknown";
  switch (self.type) {
  case 0:
    typeStr = @"down";
    break;
  case 1:
    typeStr = @"move";
    break;
  case 2:
    typeStr = @"up";
    break;
  }
  return @{
    @"type" : typeStr,
    @"x" : @(self.x),
    @"y" : @(self.y),
    @"timestamp" : @(self.timestamp)
  };
}

@end

#pragma mark - FBTouchMonitor

@interface FBTouchMonitor ()
@property(nonatomic, assign) IOHIDEventSystemClientRef hidClient;
@property(nonatomic, strong) NSMutableArray<FBTouchEvent *> *eventBuffer;
@property(nonatomic, assign) BOOL isMonitoring;
@property(nonatomic, assign) BOOL apisLoaded;
@property(nonatomic, assign) BOOL isTouchDown;
@end

static void FBTouchEventCallback(void *target, void *refcon,
                                 IOHIDEventSystemClientRef client,
                                 IOHIDEventRef event) {
  if (!_IOHIDEventGetType || !_IOHIDEventGetFloatValue)
    return;

  uint32_t eventType = _IOHIDEventGetType(event);
  if (eventType != kIOHIDEventTypeDigitizer)
    return;

  FBTouchMonitor *monitor = (__bridge FBTouchMonitor *)target;

  CFIndex eventMask =
      _IOHIDEventGetIntegerValue(event, IOHIDEventFieldDigitizerEventMask);
  IOHIDFloat x = _IOHIDEventGetFloatValue(event, IOHIDEventFieldDigitizerX);
  IOHIDFloat y = _IOHIDEventGetFloatValue(event, IOHIDEventFieldDigitizerY);

  // Convert normalized coordinates to screen coordinates using static
  // dimensions
  CGFloat screenX = x * _monitorScreenWidth;
  CGFloat screenY = y * _monitorScreenHeight;

  FBTouchEvent *touchEvent = [[FBTouchEvent alloc] init];
  touchEvent.x = screenX;
  touchEvent.y = screenY;
  touchEvent.timestamp = [[NSDate date] timeIntervalSince1970];

  // Determine event type based on mask
  BOOL isTouch = (eventMask & kIOHIDDigitizerEventTouch) != 0;
  BOOL isRange = (eventMask & kIOHIDDigitizerEventRange) != 0;

  if (isTouch) {
    if (!monitor.isTouchDown) {
      touchEvent.type = 0; // down
      monitor.isTouchDown = YES;
    } else {
      touchEvent.type = 1; // move
    }
  } else if (monitor.isTouchDown) {
    touchEvent.type = 2; // up
    monitor.isTouchDown = NO;
  } else {
    return; // Ignore hover events
  }

  @synchronized(monitor.eventBuffer) {
    [monitor.eventBuffer addObject:touchEvent];
    // Keep buffer size limited
    while (monitor.eventBuffer.count > kMaxTouchEvents) {
      [monitor.eventBuffer removeObjectAtIndex:0];
    }
  }
}

@implementation FBTouchMonitor

+ (instancetype)sharedMonitor {
  static FBTouchMonitor *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[FBTouchMonitor alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _eventBuffer = [NSMutableArray array];
    _isMonitoring = NO;
    _isTouchDown = NO;
    _apisLoaded = [self loadAPIs];
  }
  return self;
}

- (BOOL)loadAPIs {
  void *handle =
      dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
  if (!handle) {
    NSLog(@"[FBTouchMonitor] Failed to load IOKit framework");
    return NO;
  }

  _IOHIDEventSystemClientCreate = dlsym(handle, "IOHIDEventSystemClientCreate");
  _IOHIDEventSystemClientScheduleWithRunLoop =
      dlsym(handle, "IOHIDEventSystemClientScheduleWithRunLoop");
  _IOHIDEventSystemClientUnscheduleFromRunLoop =
      dlsym(handle, "IOHIDEventSystemClientUnscheduleFromRunLoop");
  _IOHIDEventSystemClientRegisterEventCallback =
      dlsym(handle, "IOHIDEventSystemClientRegisterEventCallback");
  _IOHIDEventGetType = dlsym(handle, "IOHIDEventGetType");
  _IOHIDEventGetFloatValue = dlsym(handle, "IOHIDEventGetFloatValue");
  _IOHIDEventGetIntegerValue = dlsym(handle, "IOHIDEventGetIntegerValue");

  if (!_IOHIDEventSystemClientCreate ||
      !_IOHIDEventSystemClientScheduleWithRunLoop) {
    NSLog(@"[FBTouchMonitor] Failed to load IOHIDEvent APIs");
    return NO;
  }

  NSLog(@"[FBTouchMonitor] IOHIDEvent APIs loaded successfully");
  return YES;
}

- (BOOL)startMonitoring {
  if (_isMonitoring)
    return YES;
  if (!_apisLoaded) {
    NSLog(@"[FBTouchMonitor] APIs not loaded, cannot start monitoring");
    return NO;
  }

  _hidClient = _IOHIDEventSystemClientCreate(kCFAllocatorDefault);
  if (!_hidClient) {
    NSLog(@"[FBTouchMonitor] Failed to create HID event system client");
    return NO;
  }

  _IOHIDEventSystemClientRegisterEventCallback(_hidClient, FBTouchEventCallback,
                                               (__bridge void *)self, NULL);
  _IOHIDEventSystemClientScheduleWithRunLoop(_hidClient, CFRunLoopGetMain(),
                                             kCFRunLoopDefaultMode);

  _isMonitoring = YES;
  NSLog(@"[FBTouchMonitor] Touch monitoring started");
  return YES;
}

- (void)stopMonitoring {
  if (!_isMonitoring || !_hidClient)
    return;

  _IOHIDEventSystemClientUnscheduleFromRunLoop(_hidClient, CFRunLoopGetMain(),
                                               kCFRunLoopDefaultMode);
  CFRelease(_hidClient);
  _hidClient = NULL;
  _isMonitoring = NO;

  NSLog(@"[FBTouchMonitor] Touch monitoring stopped");
}

- (NSArray<NSDictionary *> *)getRecentEvents {
  NSArray *events;
  @synchronized(_eventBuffer) {
    events = [[_eventBuffer valueForKey:@"toDictionary"] copy];
    [_eventBuffer removeAllObjects];
  }
  return events ?: @[];
}

- (NSArray<NSDictionary *> *)peekRecentEvents {
  @synchronized(_eventBuffer) {
    return [[_eventBuffer valueForKey:@"toDictionary"] copy] ?: @[];
  }
}

@end
