//
//  ECTaskPollManager.h
//  ECMAIN
//
//  用于自动轮询控制中心，拉取和管理全局动作脚本。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ECTaskPollManager : NSObject

+ (instancetype)sharedManager;

/// 单客：启动脚本拉取轮询（每 60 秒一次）
- (void)startPolling;

/// 暂停脚本轮询（在执行本地任务期间）
- (void)suspendPolling;

/// 恢复脚本轮询
- (void)resumePolling;

/// 获取目前所有保存在本地的任务
- (NSArray<NSDictionary *> *)getAllLocalTasks;

/// 强制停止当前正在执行的动作脚本
- (void)stopCurrentActionScript;

/// 删除指定 ID 的本地任务
- (void)deleteTaskWithId:(NSNumber *)taskId;

/// 判断指定任务今天是否已经执行过
- (BOOL)isTaskExecutedToday:(NSNumber *)taskId;

/// 获取指定任务今天的执行完成时间 (HH:mm:ss 格式)，未执行返回 nil
- (nullable NSString *)taskCompletionTime:(NSNumber *)taskId;

/// 获取所有任务的状态 JSON 字符串（供心跳上报使用）
- (NSString *)getTaskStatusJSON;

@end

NS_ASSUME_NONNULL_END
