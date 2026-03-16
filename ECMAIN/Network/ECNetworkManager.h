#import <Foundation/Foundation.h>

@interface ECNetworkManager : NSObject

+ (instancetype)sharedManager;
- (void)startPolling;
- (void)setServerURL:(NSString *)urlString;
- (void)handleTask:(NSDictionary *)task
        completion:(void (^)(BOOL success, id result))completion;
- (void)fetchConfig;

@end
