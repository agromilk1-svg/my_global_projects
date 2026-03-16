/**
 * FBFileLogger.h
 * File-based logging utility for ECWDA
 * Logs are saved to Documents/logs/ folder
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBFileLogger : NSObject

+ (instancetype)sharedLogger;

/**
 * Log a message with timestamp to file
 * @param tag Module tag (e.g., "OCR", "OpenCV", "NCNN")
 * @param message Log message
 */
- (void)logWithTag:(NSString *)tag message:(NSString *)message;

/**
 * Convenience method for formatted logging
 */
- (void)logWithTag:(NSString *)tag format:(NSString *)format, ... NS_FORMAT_FUNCTION(2,3);

/**
 * Get the logs directory path
 */
- (NSString *)logsDirectory;

/**
 * Get current log file path
 */
- (NSString *)currentLogFilePath;

/**
 * Read all logs from current log file
 */
- (NSString *)readCurrentLogs;

/**
 * Clear all logs
 */
- (void)clearLogs;

/**
 * Get list of all log files
 */
- (NSArray<NSString *> *)allLogFiles;

@end

// Convenience macros
#define FBLog(tag, fmt, ...) [[FBFileLogger sharedLogger] logWithTag:tag format:fmt, ##__VA_ARGS__]
#define FBLogOCR(fmt, ...) FBLog(@"OCR", fmt, ##__VA_ARGS__)
#define FBLogNCNN(fmt, ...) FBLog(@"NCNN", fmt, ##__VA_ARGS__)
#define FBLogOpenCV(fmt, ...) FBLog(@"OpenCV", fmt, ##__VA_ARGS__)
#define FBLogColor(fmt, ...) FBLog(@"Color", fmt, ##__VA_ARGS__)

NS_ASSUME_NONNULL_END
