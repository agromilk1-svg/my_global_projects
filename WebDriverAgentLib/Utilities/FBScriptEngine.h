//
//  FBScriptEngine.h
//  WebDriverAgentLib
//
//  JavaScript 脚本引擎
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 脚本执行状态
typedef NS_ENUM(NSInteger, FBScriptStatus) {
  FBScriptStatusIdle = 0,
  FBScriptStatusRunning,
  FBScriptStatusCompleted,
  FBScriptStatusFailed,
  FBScriptStatusStopped
};

/// 脚本执行结果回调
typedef void (^FBScriptCompletionBlock)(BOOL success, id _Nullable result,
                                        NSError *_Nullable error);

/// JavaScript 脚本引擎
@interface FBScriptEngine : NSObject

/// 单例
+ (instancetype)sharedEngine;

/// 当前脚本状态
@property(nonatomic, readonly) FBScriptStatus status;

/// 当前脚本ID
@property(nonatomic, readonly, nullable) NSString *currentScriptId;

/// 已执行的命令数
@property(nonatomic, readonly) NSInteger executedCommands;

/// 执行 JavaScript 脚本
/// @param script JavaScript 代码
/// @param completion 完成回调
- (NSString *)executeScript:(NSString *)script
                 completion:(nullable FBScriptCompletionBlock)completion;

/// 停止当前脚本
- (void)stopScript;

/// 获取脚本执行状态
- (NSDictionary *)getStatus;

/// 定时执行脚本
/// @param script JavaScript 代码
/// @param scheduleTime 执行时间 (格式: "HH:mm" 或 "HH:mm-HH:mm" 随机)
/// @param repeatDaily 是否每日重复
- (nullable NSString *)scheduleScript:(NSString *)script
                               atTime:(NSString *)scheduleTime
                          repeatDaily:(BOOL)repeatDaily;

/// 取消定时任务
- (void)cancelScheduledScript:(NSString *)scriptId;

/// 配置任务轮询服务器
/// @param serverURL 服务器地址
/// @param interval 轮询间隔(秒)
- (void)configureTaskPolling:(NSString *)serverURL
                    interval:(NSTimeInterval)interval;

/// 停止任务轮询
- (void)stopTaskPolling;

@end

NS_ASSUME_NONNULL_END
