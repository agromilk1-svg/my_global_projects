/**
 * FBTouchInjector - IOHIDEvent-based touch injection for standalone mode
 * Bypasses XCTest daemon by directly creating and dispatching HID touch events
 */

#import "FBTouchInjector.h"
#import "FBErrorBuilder.h"
#import "FBLogger.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

#pragma mark - IOHIDEvent Type Definitions

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef double IOHIDFloat;

// Digitizer Transducer Types
typedef NS_ENUM(uint32_t, IOHIDDigitizerTransducerType) {
  kIOHIDDigitizerTransducerTypeStylus = 0,
  kIOHIDDigitizerTransducerTypePuck = 1,
  kIOHIDDigitizerTransducerTypeFinger = 2,
  kIOHIDDigitizerTransducerTypeHand = 3
};

// Event Masks
typedef NS_OPTIONS(uint32_t, IOHIDDigitizerEventMask) {
  kIOHIDDigitizerEventRange = 1 << 0,
  kIOHIDDigitizerEventTouch = 1 << 1,
  kIOHIDDigitizerEventPosition = 1 << 2,
  kIOHIDDigitizerEventStop = 1 << 3,
  kIOHIDDigitizerEventPeak = 1 << 4,
  kIOHIDDigitizerEventIdentity = 1 << 5,
  kIOHIDDigitizerEventAttribute = 1 << 6,
  kIOHIDDigitizerEventCancel = 1 << 7,
  kIOHIDDigitizerEventStart = 1 << 8,
  kIOHIDDigitizerEventResting = 1 << 9,
  kIOHIDDigitizerEventSwipeUp = 1 << 24,
  kIOHIDDigitizerEventSwipeDown = 1 << 25,
  kIOHIDDigitizerEventSwipeLeft = 1 << 26,
  kIOHIDDigitizerEventSwipeRight = 1 << 27,
  kIOHIDDigitizerEventSwipeMask = 0xF << 24
};

#pragma mark - Function Pointers

// Client creation and management
static IOHIDEventSystemClientRef (*_IOHIDEventSystemClientCreate)(
    CFAllocatorRef allocator);
static void (*_IOHIDEventSystemClientDispatchEvent)(
    IOHIDEventSystemClientRef client, IOHIDEventRef event);

// Digitizer event creation
static IOHIDEventRef (*_IOHIDEventCreateDigitizerEvent)(
    CFAllocatorRef allocator, uint64_t timeStamp,
    IOHIDDigitizerTransducerType type, uint32_t index, uint32_t identity,
    IOHIDDigitizerEventMask eventMask, uint32_t buttonMask, IOHIDFloat x,
    IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat twist,
    Boolean range, Boolean touch, OptionBits options);

static IOHIDEventRef (*_IOHIDEventCreateDigitizerFingerEvent)(
    CFAllocatorRef allocator, uint64_t timeStamp, uint32_t index,
    uint32_t identity, IOHIDDigitizerEventMask eventMask, IOHIDFloat x,
    IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat twist,
    Boolean range, Boolean touch, OptionBits options);

// Event field setters
static void (*_IOHIDEventSetFloatValue)(IOHIDEventRef event, uint32_t field,
                                        IOHIDFloat value);
static void (*_IOHIDEventSetIntegerValue)(IOHIDEventRef event, uint32_t field,
                                          CFIndex value);
static void (*_IOHIDEventSetSenderID)(IOHIDEventRef event, uint64_t senderID);
static void (*_IOHIDEventAppendEvent)(IOHIDEventRef parent, IOHIDEventRef child,
                                      uint32_t options);

// Field constants
static const uint32_t kIOHIDEventFieldDigitizerX = 0xB0001;
static const uint32_t kIOHIDEventFieldDigitizerY = 0xB0002;
static const uint32_t kIOHIDEventFieldDigitizerMajorRadius = 0xB0014;
static const uint32_t kIOHIDEventFieldDigitizerMinorRadius = 0xB0015;
static const uint32_t kIOHIDEventFieldDigitizerIsDisplayIntegrated = 0xB001D;

static BOOL _apisLoaded = NO;
static IOHIDEventSystemClientRef _hidClient = NULL;
static CGSize _screenSize = {0, 0};

#pragma mark - Implementation

@implementation FBTouchInjector

+ (void)initialize {
  if (self == [FBTouchInjector class]) {
    [self loadAPIs];
    [self updateScreenSize];
  }
}

+ (BOOL)loadAPIs {
  if (_apisLoaded)
    return YES;

  void *handle =
      dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
  if (!handle) {
    [FBLogger log:@"[FBTouchInjector] Failed to load IOKit framework"];
    return NO;
  }

  _IOHIDEventSystemClientCreate = dlsym(handle, "IOHIDEventSystemClientCreate");
  _IOHIDEventSystemClientDispatchEvent =
      dlsym(handle, "IOHIDEventSystemClientDispatchEvent");
  _IOHIDEventCreateDigitizerEvent =
      dlsym(handle, "IOHIDEventCreateDigitizerEvent");
  _IOHIDEventCreateDigitizerFingerEvent =
      dlsym(handle, "IOHIDEventCreateDigitizerFingerEvent");
  _IOHIDEventSetFloatValue = dlsym(handle, "IOHIDEventSetFloatValue");
  _IOHIDEventSetIntegerValue = dlsym(handle, "IOHIDEventSetIntegerValue");
  _IOHIDEventSetSenderID = dlsym(handle, "IOHIDEventSetSenderID");
  _IOHIDEventAppendEvent = dlsym(handle, "IOHIDEventAppendEvent");

  if (!_IOHIDEventSystemClientCreate || !_IOHIDEventSystemClientDispatchEvent) {
    [FBLogger log:@"[FBTouchInjector] Failed to load IOHIDEvent client APIs"];
    return NO;
  }

  if (!_IOHIDEventCreateDigitizerEvent &&
      !_IOHIDEventCreateDigitizerFingerEvent) {
    [FBLogger
        log:@"[FBTouchInjector] Failed to load IOHIDEvent digitizer APIs"];
    return NO;
  }

  // Create client
  _hidClient = _IOHIDEventSystemClientCreate(kCFAllocatorDefault);
  if (!_hidClient) {
    [FBLogger
        log:@"[FBTouchInjector] Failed to create HID event system client"];
    return NO;
  }

  _apisLoaded = YES;
  [FBLogger log:@"[FBTouchInjector] IOHIDEvent APIs loaded successfully"];
  return YES;
}

+ (void)updateScreenSize {
  dispatch_async(dispatch_get_main_queue(), ^{
    _screenSize = UIScreen.mainScreen.bounds.size;
  });
}

+ (BOOL)isAvailable {
  return _apisLoaded && _hidClient != NULL;
}

+ (uint64_t)machAbsoluteTime {
  return mach_absolute_time();
}

+ (void)normalizePoint:(CGPoint)point
                   toX:(IOHIDFloat *)outX
                   toY:(IOHIDFloat *)outY {
  CGSize size = _screenSize;
  if (size.width == 0 || size.height == 0) {
    size = UIScreen.mainScreen.bounds.size;
    _screenSize = size;
  }
  *outX = point.x / size.width;
  *outY = point.y / size.height;
}

+ (IOHIDEventRef)createFingerEventAtPoint:(CGPoint)point
                                  isTouch:(BOOL)touch
                                  isRange:(BOOL)range
                                eventMask:(IOHIDDigitizerEventMask)mask {

  IOHIDFloat x, y;
  [self normalizePoint:point toX:&x toY:&y];

  uint64_t timestamp = [self machAbsoluteTime];
  IOHIDFloat pressure = touch ? 1.0 : 0.0;

  IOHIDEventRef event = NULL;

  if (_IOHIDEventCreateDigitizerFingerEvent) {
    event =
        _IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, timestamp,
                                              1,             // index
                                              2,             // identity
                                              mask, x, y, 0, // x, y, z
                                              pressure,      // tipPressure
                                              0,             // twist
                                              range,         // range
                                              touch,         // touch
                                              0              // options
        );
  } else if (_IOHIDEventCreateDigitizerEvent) {
    event = _IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, timestamp,
                                            kIOHIDDigitizerTransducerTypeFinger,
                                            1, // index
                                            2, // identity
                                            mask,
                                            0,        // buttonMask
                                            x, y, 0,  // x, y, z
                                            pressure, // tipPressure
                                            0,        // twist
                                            range,    // range
                                            touch,    // touch
                                            0         // options
    );
  }

  if (event && _IOHIDEventSetFloatValue) {
    _IOHIDEventSetFloatValue(event, kIOHIDEventFieldDigitizerMajorRadius, 0.02);
    _IOHIDEventSetFloatValue(event, kIOHIDEventFieldDigitizerMinorRadius, 0.02);
  }

  if (event && _IOHIDEventSetIntegerValue) {
    _IOHIDEventSetIntegerValue(event,
                               kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
  }

  return event;
}

+ (BOOL)dispatchEvent:(IOHIDEventRef)event error:(NSError **)error {
  if (!event) {
    if (error) {
      *error = [[FBErrorBuilder builder]
                   withDescription:@"Failed to create HID event"]
                   .build;
    }
    return NO;
  }

  if (!_hidClient) {
    CFRelease(event);
    if (error) {
      *error = [[FBErrorBuilder builder]
                   withDescription:@"HID event system client not available"]
                   .build;
    }
    return NO;
  }

  _IOHIDEventSystemClientDispatchEvent(_hidClient, event);
  CFRelease(event);

  return YES;
}

#pragma mark - Public APIs

+ (BOOL)tapAtPoint:(CGPoint)point error:(NSError **)error {
  if (![self isAvailable]) {
    if (error) {
      *error = [[FBErrorBuilder builder]
                   withDescription:@"IOHIDEvent touch injection not available"]
                   .build;
    }
    return NO;
  }

  [FBLogger logFmt:@"[FBTouchInjector] Tap at (%.1f, %.1f)", point.x, point.y];

  // Touch down
  IOHIDDigitizerEventMask downMask = kIOHIDDigitizerEventRange |
                                     kIOHIDDigitizerEventTouch |
                                     kIOHIDDigitizerEventPosition;
  IOHIDEventRef downEvent = [self createFingerEventAtPoint:point
                                                   isTouch:YES
                                                   isRange:YES
                                                 eventMask:downMask];
  if (![self dispatchEvent:downEvent error:error]) {
    return NO;
  }

  // Small delay
  [NSThread sleepForTimeInterval:0.05];

  // Touch up
  IOHIDDigitizerEventMask upMask = kIOHIDDigitizerEventPosition;
  IOHIDEventRef upEvent = [self createFingerEventAtPoint:point
                                                 isTouch:NO
                                                 isRange:NO
                                               eventMask:upMask];
  return [self dispatchEvent:upEvent error:error];
}

+ (BOOL)longPressAtPoint:(CGPoint)point
                duration:(NSTimeInterval)duration
                   error:(NSError **)error {
  if (![self isAvailable]) {
    if (error) {
      *error = [[FBErrorBuilder builder]
                   withDescription:@"IOHIDEvent touch injection not available"]
                   .build;
    }
    return NO;
  }

  [FBLogger logFmt:@"[FBTouchInjector] Long press at (%.1f, %.1f) for %.2fs",
                   point.x, point.y, duration];

  // Touch down
  IOHIDDigitizerEventMask downMask = kIOHIDDigitizerEventRange |
                                     kIOHIDDigitizerEventTouch |
                                     kIOHIDDigitizerEventPosition;
  IOHIDEventRef downEvent = [self createFingerEventAtPoint:point
                                                   isTouch:YES
                                                   isRange:YES
                                                 eventMask:downMask];
  if (![self dispatchEvent:downEvent error:error]) {
    return NO;
  }

  // Hold
  [NSThread sleepForTimeInterval:duration];

  // Touch up
  IOHIDDigitizerEventMask upMask = kIOHIDDigitizerEventPosition;
  IOHIDEventRef upEvent = [self createFingerEventAtPoint:point
                                                 isTouch:NO
                                                 isRange:NO
                                               eventMask:upMask];
  return [self dispatchEvent:upEvent error:error];
}

+ (BOOL)swipeFromPoint:(CGPoint)fromPoint
               toPoint:(CGPoint)toPoint
              duration:(NSTimeInterval)duration
                 error:(NSError **)error {
  if (![self isAvailable]) {
    if (error) {
      *error = [[FBErrorBuilder builder]
                   withDescription:@"IOHIDEvent touch injection not available"]
                   .build;
    }
    return NO;
  }

  [FBLogger logFmt:@"[FBTouchInjector] Swipe from (%.1f, %.1f) to (%.1f, %.1f)",
                   fromPoint.x, fromPoint.y, toPoint.x, toPoint.y];

  // Touch down at start
  IOHIDDigitizerEventMask downMask = kIOHIDDigitizerEventRange |
                                     kIOHIDDigitizerEventTouch |
                                     kIOHIDDigitizerEventPosition;
  IOHIDEventRef downEvent = [self createFingerEventAtPoint:fromPoint
                                                   isTouch:YES
                                                   isRange:YES
                                                 eventMask:downMask];
  if (![self dispatchEvent:downEvent error:error]) {
    return NO;
  }

  // Move through intermediate points
  NSInteger steps = MAX(1, (NSInteger)(duration / 0.016)); // ~60fps
  CGFloat dx = (toPoint.x - fromPoint.x) / steps;
  CGFloat dy = (toPoint.y - fromPoint.y) / steps;
  NSTimeInterval stepInterval = duration / steps;

  for (NSInteger i = 1; i <= steps; i++) {
    CGPoint currentPoint =
        CGPointMake(fromPoint.x + dx * i, fromPoint.y + dy * i);

    IOHIDDigitizerEventMask moveMask = kIOHIDDigitizerEventPosition;
    IOHIDEventRef moveEvent = [self createFingerEventAtPoint:currentPoint
                                                     isTouch:YES
                                                     isRange:YES
                                                   eventMask:moveMask];

    if (![self dispatchEvent:moveEvent error:nil]) {
      // Continue even if some move events fail
    }

    [NSThread sleepForTimeInterval:stepInterval];
  }

  // Touch up at end
  IOHIDDigitizerEventMask upMask = kIOHIDDigitizerEventPosition;
  IOHIDEventRef upEvent = [self createFingerEventAtPoint:toPoint
                                                 isTouch:NO
                                                 isRange:NO
                                               eventMask:upMask];
  return [self dispatchEvent:upEvent error:error];
}

@end
