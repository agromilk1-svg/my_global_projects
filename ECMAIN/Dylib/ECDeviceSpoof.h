//
//  ECDeviceSpoof.h
//  ECDeviceSpoof
//
//  设备信息伪装 dylib 头文件
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 初始化设备伪装（dylib 加载时自动调用）
void ECDeviceSpoofInitialize(void);

NS_ASSUME_NONNULL_END
