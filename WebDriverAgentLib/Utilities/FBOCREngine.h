//
//  FBOCREngine.h
//  WebDriverAgentLib
//
//  NCNN + PaddleOCR 文字识别引擎
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBOCRTextResult : NSObject

@property(nonatomic, copy) NSString *text;
@property(nonatomic, assign) CGRect frame;
@property(nonatomic, assign) float confidence;

+ (instancetype)resultWithText:(NSString *)text
                         frame:(CGRect)frame
                    confidence:(float)confidence;

- (NSDictionary *)toDictionary;

@end

@interface FBOCREngine : NSObject

/// 单例
+ (instancetype)sharedEngine;

/// 初始化 OCR 模型
/// @return 是否成功
- (BOOL)loadModels;

/// 是否已加载模型
@property(nonatomic, readonly) BOOL isModelLoaded;

/// OCR 识别
/// @param image 要识别的图片
/// @return 识别结果数组
- (NSArray<FBOCRTextResult *> *)recognizeText:(UIImage *)image;

/// OCR 识别指定区域
/// @param image 要识别的图片
/// @param region 识别区域
/// @return 识别结果数组
- (NSArray<FBOCRTextResult *> *)recognizeText:(UIImage *)image
                                     inRegion:(CGRect)region;

/// 查找指定文字
/// @param text 要查找的文字
/// @param image 要搜索的图片
/// @return 找到返回结果，否则 nil
- (nullable FBOCRTextResult *)findText:(NSString *)text
                               inImage:(UIImage *)image;

/// 找图
/// @param templateImage 模板图片
/// @param targetImage 目标图片(大图)
/// @param threshold 相似度阈值 (0.0 - 1.0)
/// @return 包含 'found', 'x', 'y', 'confidence' 等信息的字典
- (NSDictionary *)findImage:(UIImage *)templateImage
                    inImage:(UIImage *)targetImage
                  threshold:(float)threshold;

@end

NS_ASSUME_NONNULL_END
