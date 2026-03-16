/**
 * FBTouchInjector - IOHIDEvent-based touch injection for standalone mode
 * Bypasses XCTest daemon by directly creating and dispatching HID touch events
 */

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBTouchInjector : NSObject

/**
 * Check if IOHIDEvent touch injection is available
 * @return YES if required APIs are accessible
 */
+ (BOOL)isAvailable;

/**
 * Perform a tap at the specified screen coordinates
 * @param point Screen coordinates (in points)
 * @param error Error output
 * @return YES on success
 */
+ (BOOL)tapAtPoint:(CGPoint)point error:(NSError **)error;

/**
 * Perform a long press at the specified coordinates
 * @param point Screen coordinates (in points)
 * @param duration Press duration in seconds
 * @param error Error output
 * @return YES on success
 */
+ (BOOL)longPressAtPoint:(CGPoint)point
                duration:(NSTimeInterval)duration
                   error:(NSError **)error;

/**
 * Perform a swipe gesture
 * @param fromPoint Starting coordinates
 * @param toPoint Ending coordinates
 * @param duration Swipe duration in seconds
 * @param error Error output
 * @return YES on success
 */
+ (BOOL)swipeFromPoint:(CGPoint)fromPoint
               toPoint:(CGPoint)toPoint
              duration:(NSTimeInterval)duration
                 error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
