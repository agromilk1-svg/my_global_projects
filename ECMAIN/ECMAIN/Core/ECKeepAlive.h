#import <Foundation/Foundation.h>

@interface ECKeepAlive : NSObject

+ (instancetype)sharedInstance;
- (void)start;
- (void)selfCheck; // [优化] 暴露给心跳回调合并调用

@end
