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
- (BOOL)lock;
- (BOOL)volumeUp;
- (BOOL)volumeDown;
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
JSExportAs(findElement, -(NSDictionary *)findElement : (NSString *)predicate);
JSExportAs(tapElement, -(BOOL)tapElement : (NSString *)predicate);
JSExportAs(getElementText, -(NSString *)getElementText : (NSString *)predicate);
JSExportAs(getElementAttribute, -(NSString *)getElementAttribute : (NSString *)predicate attribute:(NSString *)attr);
- (BOOL)tapText:(NSString *)text;
- (NSDictionary *)ocr;

// Image / Color
JSExportAs(findImage, -(NSDictionary *)findImage : (NSString *)
                          templateBase64 threshold : (NSNumber *)threshold);
JSExportAs(getColorAt,
           -(NSString *)getColorAt : (NSNumber *)x y : (NSNumber *)y);
JSExportAs(findMultiColor,
           -(NSDictionary *)findMultiColor : (NSString *)colors sim : (NSNumber *)sim);
// [v1955新增] 主动释放截图缓存内存（在不再需要找图时调用，减轻视频流场景下的内存压力）
- (void)clearScreenshotCache;
JSExportAs(downloadToAlbum, 
           -(BOOL)downloadToAlbum:(NSString *)urlStr);
JSExportAs(downloadOneTimeMedia,
           -(BOOL)downloadOneTimeMedia:(NSString *)type group:(NSString *)group);

- (NSString *)getRandomTag;
- (NSString *)getRandomBio;
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

// 全局弹窗（在 iOS 设备上弹出系统级 Alert，脚本会阻塞直到用户点击 OK）
- (BOOL)showAlert:(NSString *)message;

// 评论数据引擎
JSExportAs(syncCommentsFromServer,
           -(BOOL)syncCommentsFromServer : (NSString *)serverUrl);
JSExportAs(getRandomComment,
           -(NSString *)getRandomComment : (NSString *)language);

// TikTok 主账号数据读取（从设备配置中获取主账号信息并写入剪切板）
- (NSString *)getMasterTkAccount;
- (NSString *)getMasterTkPassword;
- (NSString *)getMasterTkEmail;

// 立即同步配置（触发心跳包立即向服务器获取最新配置）
- (BOOL)syncConfig;

// 下载 IPA 文件到应用管理已下载目录
- (BOOL)downloadIPA:(NSString *)url;

// 自动化注入安装 IPA（远程脚本调用，无 UI 交互）
// config 参数字典：
//   filename:            IPA 文件名（在 ImportedIPAs 目录搜索，支持模糊匹配）
//   clone_number:        分身编号（"1","2"等），留空或 "0" 保持原包（自动生成 BundleID/名称）
//   custom_bundle_id:    [高级] 手动指定完整 BundleID（优先级高于 clone_number）
//   custom_display_name: [高级] 手动指定桌面显示名称
//   spoof_config:        伪装参数字典（可选），键值与 ECDeviceInfoManager 一致
//                        完整键列表：machineModel, deviceModel, deviceName, productName,
//                        screenWidth, screenHeight, screenScale, nativeBounds, maxFPS,
//                        systemVersion, systemBuildVersion, kernelVersion, systemName,
//                        carrierName, mobileCountryCode, mobileNetworkCode, carrierCountry,
//                        localeIdentifier, timezone, currencyCode, storeRegion, priorityRegion,
//                        languageCode, preferredLanguage, systemLanguage, btdCurrentLanguage,
//                        enableNetworkInterception, disableQUIC, networkType, countryCode
- (NSDictionary *)installIPA:(NSDictionary *)config;

// 提前上报任务完成（原集成在 airplaneOn 中，现解耦为独立动作）
- (void)reportFinished;

// 在脚本执行中主动报告错误并中断由于业务异常导致的后续脚本执行
- (void)reportErrorAndAbort:(NSString *)message;

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

// 中断当前正在执行的脚本（立即生效）
- (void)interruptExecution;

@end

NS_ASSUME_NONNULL_END
