/**
 * FBScreenshotFallback - IOSurface-based screenshot for standalone mode
 * Uses private APIs to capture screen without XCTest daemon
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBScreenshotFallback : NSObject

/**
 * Takes a screenshot using IOSurface/private APIs
 * This is used as fallback when XCTest daemon is not available (standalone
 * mode)
 *
 * @param compressionQuality JPEG compression quality (0.0 - 1.0)
 * @param error Error output
 * @return JPEG data or nil on failure
 */
+ (nullable NSData *)takeScreenshotWithCompressionQuality:
                         (CGFloat)compressionQuality
                                                    error:(NSError **)error;

/**
 * Check if fallback screenshot method is available
 * @return YES if private APIs are accessible
 */
+ (BOOL)isAvailable;

@end

NS_ASSUME_NONNULL_END
