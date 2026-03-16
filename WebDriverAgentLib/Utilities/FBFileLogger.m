/**
 * FBFileLogger.m
 * File-based logging utility for ECWDA
 */

#import "FBFileLogger.h"

@interface FBFileLogger ()
@property(nonatomic, strong) NSString *logsPath;
@property(nonatomic, strong) NSDateFormatter *dateFormatter;
@property(nonatomic, strong) NSDateFormatter *fileNameFormatter;
@property(nonatomic, strong) dispatch_queue_t logQueue;
@end

@implementation FBFileLogger

+ (instancetype)sharedLogger {
  static FBFileLogger *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[FBFileLogger alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    // Create logs directory in Documents
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES);
    NSString *documentsPath = paths.firstObject;
    _logsPath = [documentsPath stringByAppendingPathComponent:@"logs"];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:_logsPath]) {
      NSError *error = nil;
      [fm createDirectoryAtPath:_logsPath
          withIntermediateDirectories:YES
                           attributes:nil
                                error:&error];
      if (error) {
        // NSLog(@"[FBFileLogger] Failed to create logs directory: %@", error);
      }
    }

    // Setup formatters
    _dateFormatter = [[NSDateFormatter alloc] init];
    [_dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];

    _fileNameFormatter = [[NSDateFormatter alloc] init];
    [_fileNameFormatter setDateFormat:@"yyyy-MM-dd"];

    // Serial queue for thread-safe file writes
    _logQueue =
        dispatch_queue_create("com.ecwda.filelogger", DISPATCH_QUEUE_SERIAL);

    // Log startup
    [self logWithTag:@"System" message:@"=== ECWDA Logger Started ==="];
    [self logWithTag:@"System" format:@"Logs directory: %@", _logsPath];
  }
  return self;
}

- (NSString *)logsDirectory {
  return self.logsPath;
}

- (NSString *)currentLogFilePath {
  NSString *fileName = [NSString
      stringWithFormat:@"ecwda_%@.log",
                       [self.fileNameFormatter stringFromDate:[NSDate date]]];
  return [self.logsPath stringByAppendingPathComponent:fileName];
}

- (void)logWithTag:(NSString *)tag message:(NSString *)message {
  return; // File logging disabled by user request
  dispatch_async(self.logQueue, ^{
    @try {
      NSString *timestamp = [self.dateFormatter stringFromDate:[NSDate date]];
      NSString *logLine = [NSString
          stringWithFormat:@"[%@] [%@] %@\n", timestamp, tag, message];

      // Also output to NSLog for Xcode console
      // NSLog(@"[ECWDA/%@] %@", tag, message);

      // Append to file
      NSString *filePath = [self currentLogFilePath];
      NSFileHandle *fileHandle =
          [NSFileHandle fileHandleForWritingAtPath:filePath];

      if (fileHandle) {
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[logLine dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
      } else {
        // File doesn't exist, create it
        [logLine writeToFile:filePath
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:nil];
      }
    } @catch (NSException *exception) {
      // NSLog(@"[FBFileLogger] Write error: %@", exception);
    }
  });
}

- (void)logWithTag:(NSString *)tag format:(NSString *)format, ... {
  va_list args;
  va_start(args, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);

  [self logWithTag:tag message:message];
}

- (NSString *)readCurrentLogs {
  NSString *filePath = [self currentLogFilePath];
  NSError *error = nil;
  NSString *content = [NSString stringWithContentsOfFile:filePath
                                                encoding:NSUTF8StringEncoding
                                                   error:&error];
  if (error) {
    return [NSString
        stringWithFormat:@"Error reading logs: %@", error.localizedDescription];
  }
  return content ?: @"(No logs yet)";
}

- (void)clearLogs {
  dispatch_async(self.logQueue, ^{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray *files = [fm contentsOfDirectoryAtPath:self.logsPath error:&error];

    for (NSString *file in files) {
      if ([file hasSuffix:@".log"]) {
        NSString *filePath =
            [self.logsPath stringByAppendingPathComponent:file];
        [fm removeItemAtPath:filePath error:nil];
      }
    }

    [self logWithTag:@"System" message:@"Logs cleared"];
  });
}

- (NSArray<NSString *> *)allLogFiles {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *error = nil;
  NSArray *files = [fm contentsOfDirectoryAtPath:self.logsPath error:&error];

  NSMutableArray *logFiles = [NSMutableArray array];
  for (NSString *file in files) {
    if ([file hasSuffix:@".log"]) {
      [logFiles addObject:file];
    }
  }

  return [logFiles sortedArrayUsingSelector:@selector(compare:)];
}

@end
