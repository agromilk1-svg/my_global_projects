#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol ProxyTypeSelectionDelegate <NSObject>
- (void)didSelectProxyType:(NSString *)type;
@end

@interface ProxyTypeSelectionViewController : UITableViewController

@property(nonatomic, weak) id<ProxyTypeSelectionDelegate> delegate;
@property(nonatomic, strong) NSString *currentType;

@end

NS_ASSUME_NONNULL_END
