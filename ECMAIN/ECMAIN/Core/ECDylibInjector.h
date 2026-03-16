//
//  ECDylibInjector.h
//  ECMAIN
//
//  Dylib 注入工具 - 修改 Mach-O 添加 LC_LOAD_DYLIB 命令
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ECDylibInjector : NSObject

/// 注入 dylib 到目标 APP
/// @param appPath APP 路径 (如
/// /var/containers/Bundle/Application/xxx/Target.app)
/// @param dylibName dylib 文件名 (如 ECDeviceSpoof.dylib)
/// @param error 错误信息
/// @return 是否成功
+ (BOOL)injectDylib:(NSString *)dylibName
            intoApp:(NSString *)appPath
              error:(NSError **)error;

/// 检查 APP 是否已注入特定 dylib
+ (BOOL)isApp:(NSString *)appPath injectedWithDylib:(NSString *)dylibName;

/// 从 APP 移除注入的 dylib
+ (BOOL)removeDylib:(NSString *)dylibName
            fromApp:(NSString *)appPath
              error:(NSError **)error;

/// 获取我们打包的 dylib 路径
+ (nullable NSString *)bundledDylibPath;

@end

NS_ASSUME_NONNULL_END
