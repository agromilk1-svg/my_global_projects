#import <Foundation/Foundation.h>

@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (void)sendActions:(NSSet *)actions withResult:(void (^)(NSError *))result;
- (void)reboot;
@end
