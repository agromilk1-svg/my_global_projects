//
//  ECOneshotTaskManager.h
//  ECMAIN
//
//  独立的一次性任务轮询管理器。
//  以 30 秒为周期查询专属于当前设备的一次性任务，
//  执行时抢占所有常规脚本和在线升级逻辑。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 全局标志：一次性任务执行中（供在线升级检查用）
extern BOOL EC_ONESHOT_EXECUTING;

@interface ECOneshotTaskManager : NSObject

+ (instancetype)sharedManager;

/// 启动 30 秒一次的轮询定时器
- (void)startPolling;

/// 暂停轮询
- (void)suspendPolling;

/// 恢复轮询
- (void)resumePolling;

@end

NS_ASSUME_NONNULL_END
