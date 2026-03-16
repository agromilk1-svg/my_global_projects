/**
 * Copyright (c) 2018-present, Facebook, Inc.
 * All rights reserved.
 *
 * FBTouchMonitor - Monitor real user touch events on device
 * Uses IOHIDEventSystemClient to capture HID touch events
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBTouchEvent : NSObject

@property(nonatomic, assign) NSInteger type; // 0=down, 1=move, 2=up
@property(nonatomic, assign) CGFloat x;
@property(nonatomic, assign) CGFloat y;
@property(nonatomic, assign) NSTimeInterval timestamp;

- (NSDictionary *)toDictionary;

@end

@interface FBTouchMonitor : NSObject

+ (instancetype)sharedMonitor;

/// Start monitoring touch events
- (BOOL)startMonitoring;

/// Stop monitoring touch events
- (void)stopMonitoring;

/// Get recent touch events (clears the buffer)
- (NSArray<NSDictionary *> *)getRecentEvents;

/// Get recent touch events without clearing
- (NSArray<NSDictionary *> *)peekRecentEvents;

/// Check if monitoring is active
@property(nonatomic, readonly) BOOL isMonitoring;

@end

NS_ASSUME_NONNULL_END
