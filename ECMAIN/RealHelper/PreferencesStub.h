#import <UIKit/UIKit.h>

@interface PSSpecifier : NSObject
@property(retain, nonatomic) NSString *name;
@property(retain, nonatomic) NSString *identifier;
@property(nonatomic) SEL buttonAction;
+ (instancetype)emptyGroupSpecifier;
+ (instancetype)preferenceSpecifierNamed:(NSString *)name
                                  target:(id)target
                                     set:(SEL)set
                                     get:(SEL)get
                                  detail:(Class)detail
                                    cell:(long)cell
                                    edit:(Class)edit;
- (void)setProperty:(id)value forKey:(NSString *)key;
@end

@interface PSListController : UIViewController {
  NSMutableArray *_specifiers;
}
- (NSMutableArray *)specifiers;
- (void)reloadSpecifiers;
- (void)handleUninstallation; // Potential override?
@property(nonatomic, retain) id navigationItem;
@end

// Cell Types
#define PSGroupCell 0
#define PSTitleValueCell 2
#define PSButtonCell 13

// Forward declare private class strings
// "PSDeleteButtonCell"
