#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ECRegionInfo : NSObject
@property(nonatomic, copy) NSString *countryCode;
@property(nonatomic, copy) NSString *displayName; // English + Chinese
@property(nonatomic, copy) NSString *languageCode;
@property(nonatomic, copy) NSString *localeIdentifier;
@property(nonatomic, copy) NSString *currencyCode;
@property(nonatomic, copy) NSString *timezone;
@end

typedef void (^ECRegionSelectionBlock)(ECRegionInfo *info);

@interface ECCountrySelectionViewController : UITableViewController

@property(nonatomic, copy) ECRegionSelectionBlock selectionBlock;

@end

NS_ASSUME_NONNULL_END
