/**
 * FBXCTestBootstrap - Bootstrap XCTest session without xcodebuild
 * Establishes XPC connection to testmanagerd daemon
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBXCTestBootstrap : NSObject

/**
 * Attempt to bootstrap XCTest session by connecting to testmanagerd
 * @return YES if connection was established successfully
 */
+ (BOOL)bootstrapWithError:(NSError **)error;

/**
 * Check if XCTest session is active
 */
+ (BOOL)isSessionActive;

@end

NS_ASSUME_NONNULL_END
