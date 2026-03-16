#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ECFileBrowserViewController : UITableViewController

- (instancetype)initWithPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
