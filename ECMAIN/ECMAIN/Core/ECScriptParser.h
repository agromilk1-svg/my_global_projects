//
//  ECScriptParser.h
//  ECMAIN
//
//  JavaScript script engine for ECMAIN (JavaScriptCore)
//

#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

NS_ASSUME_NONNULL_BEGIN

@protocol WDAJSExport <JSExport>
// Basic Actions
JSExportAs(tap, -(BOOL)tap : (NSNumber *)x y : (NSNumber *)y);
JSExportAs(doubleTap, -(BOOL)doubleTap : (NSNumber *)x y : (NSNumber *)y);
JSExportAs(longPress, -(BOOL)longPress : (NSNumber *)x y : (NSNumber *)
                          y duration : (NSNumber *)duration);
JSExportAs(swipe, -(BOOL)swipe : (NSNumber *)fromX fromY : (NSNumber *)
                      fromY toX : (NSNumber *)toX toY : (NSNumber *)
                          toY duration : (NSNumber *)duration);
- (BOOL)sleep:(NSNumber *)seconds;
- (BOOL)input:(NSString *)text;
- (BOOL)home;
- (NSDictionary *)screenshot;

// App Management
- (BOOL)launch:(NSString *)bundleId;
- (BOOL)terminate:(NSString *)bundleId;
- (BOOL)terminateAll;
- (BOOL)wipeApp:(NSString *)bundleId;

// 系统控制
- (BOOL)airplaneOn;
- (BOOL)airplaneOff;

// 网络配置
JSExportAs(setStaticIP,
           -(BOOL)setStaticIP : (NSString *)ip subnet : (NSString *)
               subnet gateway : (NSString *)gateway dns : (NSString *)dns);
JSExportAs(setWifi,
           -(BOOL)setWifi : (NSString *)ssid password : (NSString *)password);
- (BOOL)connectProxy:(NSString *)keyword;

// Text / OCR
JSExportAs(findText, -(NSDictionary *)findText : (NSString *)text);
- (BOOL)tapText:(NSString *)text;
- (NSDictionary *)ocr;

// Image / Color
JSExportAs(findImage, -(NSDictionary *)findImage : (NSString *)
                          templateBase64 threshold : (NSNumber *)threshold);
JSExportAs(getColorAt,
           -(NSString *)getColorAt : (NSNumber *)x y : (NSNumber *)y);
JSExportAs(findMultiColor,
           -(NSDictionary *)findMultiColor : (NSString *)colors);

// Utils
- (void)log:(NSString *)message;
JSExportAs(randomInt,
           -(NSInteger)randomInt : (NSInteger)min max : (NSInteger)max);
JSExportAs(random, -(double)random : (double)min max : (double)max);
// 系统弹窗 Alert
- (NSString *)getAlertText;
- (NSArray *)getAlertButtons;
- (BOOL)acceptAlert;
- (BOOL)dismissAlert;
- (BOOL)clickAlertButton:(NSString *)label;

// VPN
- (BOOL)connectVPN:(NSDictionary *)config;
- (BOOL)isVPNConnected;

// 评论数据引擎
JSExportAs(syncCommentsFromServer,
           -(BOOL)syncCommentsFromServer : (NSString *)serverUrl);
JSExportAs(getRandomComment,
           -(NSString *)getRandomComment : (NSString *)language);

@end

@interface ECScriptParser : NSObject <WDAJSExport>

+ (instancetype)sharedParser;

// Parse and execute a script (Legacy Async)
- (void)executeScript:(NSString *)script
           completion:(void (^)(BOOL success, NSArray *results))completion;

// Execute script synchronously, returning final JS value and all logs generated
// during execution
- (NSDictionary *)executeScriptSync:(NSString *)script;

// Global Log Buffer for Web Server polling
+ (void)addGlobalLog:(NSDictionary *)logDict;
+ (NSArray *)popGlobalLogs;

@end

NS_ASSUME_NONNULL_END
