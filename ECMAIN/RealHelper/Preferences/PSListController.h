#import <UIKit/UIKit.h>

#import "PSSpecifier.h"

@interface PSListController : UIViewController {
  NSMutableArray *_specifiers;
}
- (NSMutableArray *)specifiers;
- (void)reloadSpecifiers;
- (void)handleUninstallation;
@property(nonatomic, retain) id navigationItem;
@end

#define PSGroupCell 0
#define PSTitleValueCell 2
#define PSButtonCell 13
