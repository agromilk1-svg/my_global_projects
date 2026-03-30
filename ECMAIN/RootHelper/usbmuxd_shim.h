// usbmuxd_shim.h - 本地 usbmuxd 模拟器
// 在 /var/run/usbmuxd 创建 Unix Socket，模拟 usbmuxd 协议
// 让 go-ios 在脱机环境下以为自己仍然在与真实的 usbmuxd 通信

#import <Foundation/Foundation.h>

// 启动模拟器线程，在 /var/run/usbmuxd_shim.sock 创建假 socket
// 返回 YES 代表 socket 已就绪
BOOL startUsbmuxdShimWithUDID(NSString *udid);

// 停止模拟器
void stopUsbmuxdShim(void);
