//
//  ECLogManager.h
//  ECMAIN
//
//  Unified Logging System
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ECLogManager : NSObject

+ (instancetype)sharedManager;

// Log a message with format
- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

// Read entire log content
- (NSString *)readLog;

// Clear all logs
- (void)clearLog;

// Sync logs from App Group to Documents (for Files app visibility)
// Returns the path of the synced file
- (NSString *)syncToDocuments;

// Get current log file path (App Group)
- (NSString *)currentLogPath;

@end

NS_ASSUME_NONNULL_END
