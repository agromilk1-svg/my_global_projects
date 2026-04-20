
#import <Foundation/Foundation.h>
#import <mach-o/dyld_images.h>
#import <mach-o/loader.h>
#import <mach/mach.h>

#pragma mark - Decrypt Export Log

// 脱壳导出日志路径
#define DECRYPT_EXPORT_LOG_PATH @"/var/mobile/Media/ecmain_decrypt_export.log"

// 写入脱壳日志到文件（线程安全）
void ECDecryptLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// 清空脱壳日志文件（在每次脱壳开始前调用）
void ECDecryptLogClear(void);

#pragma mark - Main Image Info

typedef struct MainImageInfo {
  uint64_t loadAddress; // main executable Mach-O header address
  NSString *path;       // main executable path
  BOOL ok;
} MainImageInfo_t;

NSString *NSStringFromMainImageInfo(MainImageInfo_t info);

MainImageInfo_t imageInfoForPIDWithRetry(const char *sourcePath, vm_map_t task,
                                         pid_t pid);

// 通过扫描 VM Region 查找主二进制加载地址 (无需 dyld 初始化，适用于挂起状态的进程)
// 返回 0 表示未找到
uint64_t findMainBinaryLoadAddressByVMScan(vm_map_t task);

// foundEncryption: 输出参数，表示是否找到 LC_ENCRYPTION_INFO 命令
//   - YES: 找到加密命令（检查 encryptionInfo->cryptid 判断是否真正加密）
//   - NO: 未找到加密命令（二进制未加密）
BOOL readEncryptionInfo(vm_map_t task, uint64_t address,
                        struct encryption_info_command *encryptionInfo,
                        uint64_t *loadCommandAddress, BOOL *foundEncryption);

BOOL rebuildDecryptedImageAtPath(NSString *sourcePath, vm_map_t task,
                                 uint64_t loadAddress,
                                 struct encryption_info_command *encryptionInfo,
                                 uint64_t loadCommandAddress,
                                 NSString *outputPath);

// 在 dyld image list 中按路径前缀查找镜像加载地址
// pathPrefix: 要匹配的路径前缀（如 app.bundlePath）
// imageName: 镜像名称（如 "MyFramework" 或 "Extension.appex/Extension"）
// task: 目标进程的 task port
// pid: 目标进程 PID
// outLoadAddress: 输出参数，找到的加载地址
// outFullPath: 输出参数，找到的完整路径
// 返回值: YES 表示找到，NO 表示未找到
BOOL findImageLoadAddress(const char *pathPrefix, const char *imageName,
                          vm_map_t task, pid_t pid, uint64_t *outLoadAddress,
                          NSString **outFullPath);

#pragma mark - Extension Process Handling

// 扩展进程信息结构
typedef struct ExtensionProcessInfo {
  pid_t pid;                // 扩展进程 PID
  char executableName[256]; // 可执行文件名
  char extBundleName[256];  // 扩展 bundle 名称 (如 AwemeWidget.appex)
} ExtensionProcessInfo_t;

// 扫描所有运行中的与目标应用相关的扩展进程
// bundlePath: 目标应用的 bundle 路径
// outProcesses: 输出参数，包含找到的扩展进程信息数组
// outCount: 输出参数，找到的扩展进程数量
// 返回值: YES 表示成功，NO 表示失败
BOOL findRunningExtensionProcesses(NSString *bundlePath,
                                   ExtensionProcessInfo_t **outProcesses,
                                   int *outCount);

// 通过进程 PID 获取扩展的加载地址并脱壳
// pid: 扩展进程的 PID
// extBinaryPath: 扩展可执行文件的完整路径
// outputPath: 脱壳后文件的输出路径
// errorMessage: 输出参数，错误信息
// 返回值: YES 表示成功，NO 表示失败
BOOL decryptExtensionProcess(pid_t pid, NSString *extBinaryPath,
                             NSString *outputPath, NSString **errorMessage);

#pragma mark - Encryption Detection

// 加密检测结果
typedef enum {
  EncryptionStatusUnknown = 0,   // 无法确定
  EncryptionStatusEncrypted = 1, // 已加密 (cryptid = 1)
  EncryptionStatusDecrypted = 2, // 已脱壳 (cryptid = 0)
  EncryptionStatusNotFound = 3   // 没有加密段 (非 App Store 应用)
} EncryptionStatus;

// 检测文件的加密状态
// binaryPath: Mach-O 二进制文件路径
// 返回值: 加密状态枚举值
EncryptionStatus checkBinaryEncryptionStatus(NSString *binaryPath);

// 返回加密状态的描述字符串
NSString *encryptionStatusDescription(EncryptionStatus status);
