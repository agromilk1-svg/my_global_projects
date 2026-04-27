//
//  ECProfileSpoof.h
//  ECProfileSpoof (方案 C)
//
//  核心 Hook 引擎头文件
//  基于原版 TikTok 注入，实现数据隔离 + 设备伪装
//  不修改 Bundle ID，不需要 Bundle ID 伪装
//

#import <Foundation/Foundation.h>

/// 方案 C 初始化入口（在 constructor 中调用）
void ECProfileSpoofInitialize(void);
