//
//  ECDeviceInfoViewController.h
//  ECMAIN
//
//  设备信息展示和编辑视图控制器
//

#import <UIKit/UIKit.h>

@interface ECDeviceInfoViewController : UITableViewController

/// 目标配置路径（如果为 nil，则读取/保存全局配置）
@property(nonatomic, strong, nullable) NSString *targetConfigPath;

/// 目标容器内配置路径（用于 User App 同步）
@property(nonatomic, strong, nullable) NSString *targetContainerPath;

/// 是否为编辑模式
@property(nonatomic, assign) BOOL isEditingMode;

/// 配置完成回调（用于注入安装流程）
@property(nonatomic, copy, nullable) void (^completionBlock)(void);

/// 配置取消回调（用于注入安装流程）
@property(nonatomic, copy, nullable) void (^cancelBlock)(void);

@end
