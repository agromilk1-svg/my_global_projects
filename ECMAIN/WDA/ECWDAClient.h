#import <Foundation/Foundation.h>

@interface ECWDAClient : NSObject

+ (instancetype)sharedClient;
- (void)executeScript:(NSString *)script
           completion:(void (^)(BOOL success, NSDictionary *result))completion;
- (void)statusWithCompletion:(void (^)(BOOL success,
                                       NSDictionary *status))completion;

@end
