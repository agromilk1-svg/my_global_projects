//
//  ECLogManager.m
//  ECMAIN
//
//  Unified Logging System
//

#import "ECLogManager.h"

// Update this to match your App Group ID
static NSString *const kAppGroupID = @"group.com.ecmain.shared";
static NSString *const kLogFileName = @"ecmain.log";
static NSString *const kTunnelLogFileName = @"tunnel.log";

@interface ECLogManager ()
@property(nonatomic, strong) NSDateFormatter *dateFormatter;
@property(nonatomic, strong) dispatch_queue_t logQueue;
@end

@implementation ECLogManager

+ (instancetype)sharedManager {
  static ECLogManager *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[ECLogManager alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _dateFormatter = [[NSDateFormatter alloc] init];
    [_dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    _logQueue =
        dispatch_queue_create("com.ecmain.logQueue", DISPATCH_QUEUE_SERIAL);

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(handleExternalLog:)
               name:@"TSLogNotification"
             object:nil];
  }
  return self;
}

- (void)handleExternalLog:(NSNotification *)note {
  id obj = note.object;
  if ([obj isKindOfClass:[NSString class]]) {
    [self log:@"%@", obj];
  }
}

- (NSString *)currentLogPath {
  NSURL *containerURL = [[NSFileManager defaultManager]
      containerURLForSecurityApplicationGroupIdentifier:kAppGroupID];
  if (!containerURL) {
    // Fallback to Documents if App Group is invalid
    return [[NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES) firstObject]
        stringByAppendingPathComponent:kLogFileName];
  }
  return [containerURL.path stringByAppendingPathComponent:kLogFileName];
}

- (NSString *)tunnelLogPath {
  NSURL *containerURL = [[NSFileManager defaultManager]
      containerURLForSecurityApplicationGroupIdentifier:kAppGroupID];
  if (!containerURL) {
    return nil;
  }
  return [containerURL.path stringByAppendingPathComponent:kTunnelLogFileName];
}

- (void)log:(NSString *)format, ... {
  va_list args;
  va_start(args, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);

  NSString *timestamp = [self.dateFormatter stringFromDate:[NSDate date]];
  NSString *logEntry =
      [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];

  // [优化] 减少 Release 模式下 NSLog 序列化造成的 CPU 开销，仅写文件
#ifdef DEBUG
  NSLog(@"%@", message);
#endif

  dispatch_async(self.logQueue, ^{
    @try {
      NSString *filePath = [self currentLogPath];
      if (!filePath)
        return;

      NSFileManager *fileManager = [NSFileManager defaultManager];

      if (![fileManager fileExistsAtPath:filePath]) {
        [logEntry writeToFile:filePath
                   atomically:YES
                     encoding:NSUTF8StringEncoding
                        error:nil];
      } else {
        NSFileHandle *fileHandle =
            [NSFileHandle fileHandleForWritingAtPath:filePath];
        if (fileHandle) {
          [fileHandle seekToEndOfFile];
          [fileHandle
              writeData:[logEntry dataUsingEncoding:NSUTF8StringEncoding]];
          [fileHandle closeFile];
        } else {
          // Fallback: append by rewriting
          NSString *existing =
              [NSString stringWithContentsOfFile:filePath
                                        encoding:NSUTF8StringEncoding
                                           error:nil];
          NSString *combined = [existing stringByAppendingString:logEntry];
          [combined writeToFile:filePath
                     atomically:YES
                       encoding:NSUTF8StringEncoding
                          error:nil];
        }
      }
    } @catch (NSException *exception) {
      // Silently ignore logging errors to prevent crash
      NSLog(@"[ECLogManager] Write error: %@", exception.reason);
    }
  });
}

- (NSString *)readLog {
  NSMutableString *combinedLog = [NSMutableString string];

  NSString *appLogPath = [self currentLogPath];
  if ([[NSFileManager defaultManager] fileExistsAtPath:appLogPath]) {
    NSString *log = [NSString stringWithContentsOfFile:appLogPath
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    if (log) {
      [combinedLog appendString:@"========== APP LOG ==========\n"];
      [combinedLog appendString:log];
      [combinedLog appendString:@"\n\n"];
    }
  }

  NSString *tunnelPath = [self tunnelLogPath];
  if (tunnelPath &&
      [[NSFileManager defaultManager] fileExistsAtPath:tunnelPath]) {
    NSString *log = [NSString stringWithContentsOfFile:tunnelPath
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    if (log) {
      [combinedLog appendString:@"========== TUNNEL LOG ==========\n"];
      [combinedLog appendString:log];
      [combinedLog appendString:@"\n"];
    }
  }

  if (combinedLog.length == 0) {
    return @"(暂无日志)";
  }
  return combinedLog;
}

- (void)clearLog {
  dispatch_async(self.logQueue, ^{
    NSString *filePath = [self currentLogPath];
    [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];

    NSString *tunnelPath = [self tunnelLogPath];
    if (tunnelPath) {
      [[NSFileManager defaultManager] removeItemAtPath:tunnelPath error:nil];
    }
  });
}

- (NSString *)syncToDocuments {
  NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                       NSUserDomainMask, YES);
  NSString *documentsDir = paths.firstObject;
  NSLog(@"[ECLogManager] Documents Directory: %@", documentsDir);
  // [self log:@"[Debug] Documents Dir: %@", documentsDir];

  NSString *logsDir = [documentsDir stringByAppendingPathComponent:@"Logs"];

  // Create Logs directory
  NSError *createError = nil;
  if (![[NSFileManager defaultManager] fileExistsAtPath:logsDir]) {
    BOOL success =
        [[NSFileManager defaultManager] createDirectoryAtPath:logsDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&createError];
    if (!success) {
      NSLog(@"[ECLogManager] Failed to create Logs dir at: %@", logsDir);
      [self log:@"[Error] Failed to create Logs dir: %@", createError];
    } else {
      //      [self log:@"[Info] Created Logs dir at: %@", logsDir];
    }
  } else {
    // [self log:@"[Info] Logs dir already exists at: %@", logsDir];
  }

  // Create placeholder README to ensure visibility in Files app
  NSString *readmePath =
      [documentsDir stringByAppendingPathComponent:@"README.txt"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:readmePath]) {
    NSString *readmeContent =
        @"ECMAIN 日志文件夹\n\n请查看 Logs 目录获取应用日志。\n";
    [readmeContent writeToFile:readmePath
                    atomically:YES
                      encoding:NSUTF8StringEncoding
                         error:nil];
    // [self log:@"[Info] Created README.txt at: %@", readmePath];
  }

  // 1. Sync App Log
  NSString *sourcePath = [self currentLogPath];
  NSString *destPath = [logsDir stringByAppendingPathComponent:kLogFileName];
  if ([[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:destPath]) {
      [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
    }
    [[NSFileManager defaultManager] copyItemAtPath:sourcePath
                                            toPath:destPath
                                             error:nil];
  }

  // 2. Sync Tunnel Log
  NSString *tunnelSource = [self tunnelLogPath];
  if (tunnelSource &&
      [[NSFileManager defaultManager] fileExistsAtPath:tunnelSource]) {
    NSString *tunnelDest =
        [logsDir stringByAppendingPathComponent:kTunnelLogFileName];
    if ([[NSFileManager defaultManager] fileExistsAtPath:tunnelDest]) {
      [[NSFileManager defaultManager] removeItemAtPath:tunnelDest error:nil];
    }
    [[NSFileManager defaultManager] copyItemAtPath:tunnelSource
                                            toPath:tunnelDest
                                             error:nil];
  }

  return destPath;
}

@end
