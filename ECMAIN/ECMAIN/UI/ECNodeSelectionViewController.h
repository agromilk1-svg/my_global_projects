#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol ECNodeSelectionDelegate <NSObject>
- (void)didSelectNodeID:(nullable NSString *)nodeID;
@end

@interface ECNodeSelectionViewController : UIViewController
@property(nonatomic, weak) id<ECNodeSelectionDelegate> delegate;
@property(nonatomic, copy, nullable) NSString *currentSelectedID;
@end

NS_ASSUME_NONNULL_END
