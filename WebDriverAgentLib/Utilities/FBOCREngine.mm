//
//  FBOCREngine.mm
//  WebDriverAgentLib
//
//  OCR Engine - Hybrid NCNN + OpenCV + Vision API with Fallback
//

// IMPORTANT: Include UIKit FIRST to define the NO macro
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Vision/Vision.h>

// Save NO macro, undef it for OpenCV, then restore
#pragma push_macro("NO")
#undef NO

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#pragma clang diagnostic ignored "-Wnullability-completeness"
#pragma clang diagnostic ignored "-Wold-style-cast"
#import <opencv2/imgcodecs/ios.h>
#import <opencv2/opencv.hpp>
#pragma clang diagnostic pop

// Restore NO macro after OpenCV
#pragma pop_macro("NO")

#import "FBOCREngine.h"

// NCNN Headers
#import <ncnn/cpu.h>
#import <ncnn/net.h>

#import <algorithm>
#import <cmath>
#import <string>
#import <vector>

// PP-OCRv5 Mobile Config
static const int RAW_SHORT_SIDE = 960;  // 恢复为 960，防止压缩比过高导致状态栏小字(如 9pt 的 VPN/电量等)丢失
static const float DET_DB_THRESH = 0.3f;
static const float DET_DB_BOX_THRESH = 0.6f;
static const float DET_DB_UNCLIP_RATIO = 1.5f;
static const int REC_IMG_H = 48;

@implementation FBOCRTextResult

+ (instancetype)resultWithText:(NSString *)text
                         frame:(CGRect)frame
                    confidence:(float)confidence {
  FBOCRTextResult *result = [[FBOCRTextResult alloc] init];
  result.text = text;
  result.frame = frame;
  result.confidence = confidence;
  return result;
}

- (NSDictionary *)toDictionary {
  return @{
    @"text" : self.text ?: @"",
    @"x" : @(self.frame.origin.x),
    @"y" : @(self.frame.origin.y),
    @"width" : @(self.frame.size.width),
    @"height" : @(self.frame.size.height),
    @"confidence" : @(self.confidence)
  };
}

@end

@interface FBOCREngine () {
  ncnn::Net _detNet;
  ncnn::Net _recNet;
  std::vector<std::string> _keys;
  ncnn::Option _opt;
  BOOL _ncnnAvailable;
}

@property(nonatomic, readwrite) BOOL isModelLoaded;

@end

@implementation FBOCREngine

+ (instancetype)sharedEngine {
  static FBOCREngine *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[FBOCREngine alloc] init];
  });
  return sharedInstance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _isModelLoaded = NO;
    _ncnnAvailable = NO;
    _opt.lightmode = true;
    _opt.num_threads = 4;  // iPhone 8+ 均至少 6 核，4 线程推理充分利用多核
    _opt.use_packing_layout = true;

    // Try to load NCNN models, but don't crash if it fails
    @try {
      [self loadModels];
    } @catch (NSException *exception) {
      NSLog(@"[FBOCREngine] Failed to load NCNN models: %@", exception);
      _ncnnAvailable = NO;
    }
  }
  return self;
}

- (BOOL)loadModels {
  if (self.isModelLoaded)
    return YES;

  @try {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *resourcePath = [bundle resourcePath];
    NSString *ocrPath = [resourcePath stringByAppendingPathComponent:@"OCR"];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *detBin = [ocrPath
        stringByAppendingPathComponent:@"ncnn_PP_OCRv5_mobile_det.ncnn.bin"];

    // Try alternative paths
    if (![fm fileExistsAtPath:detBin]) {
      ocrPath = resourcePath;
      detBin = [ocrPath
          stringByAppendingPathComponent:@"ncnn_PP_OCRv5_mobile_det.ncnn.bin"];
    }

    if (![fm fileExistsAtPath:detBin]) {
      NSLog(@"[FBOCREngine] NCNN model not found, using Vision API fallback");
      _ncnnAvailable = NO;
      self.isModelLoaded = YES; // Vision is always available
      return YES;
    }

    NSString *detParam = [ocrPath
        stringByAppendingPathComponent:@"ncnn_PP_OCRv5_mobile_det.ncnn.param"];
    NSString *recBin = [ocrPath
        stringByAppendingPathComponent:@"ncnn_PP_OCRv5_mobile_rec.ncnn.bin"];
    NSString *recParam = [ocrPath
        stringByAppendingPathComponent:@"ncnn_PP_OCRv5_mobile_rec.ncnn.param"];
    NSString *keysFile =
        [ocrPath stringByAppendingPathComponent:@"ncnn_keys.txt"];

    // Load keys
    NSError *error = nil;
    NSString *keyContent =
        [NSString stringWithContentsOfFile:keysFile
                                  encoding:NSUTF8StringEncoding
                                     error:&error];
    if (!keyContent) {
      NSLog(@"[FBOCREngine] Failed to load keys file");
      _ncnnAvailable = NO;
      self.isModelLoaded = YES;
      return YES;
    }

    _keys.clear();
    _keys.push_back("#");
    NSArray *lines = [keyContent componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
      NSString *cleanLine =
          [line stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if (cleanLine.length > 0) {
        _keys.push_back(std::string([cleanLine UTF8String]));
      }
    }
    _keys.push_back(" ");

    // Load models
    _detNet.opt = _opt;
    _recNet.opt = _opt;

    if (_detNet.load_param([detParam UTF8String]) != 0 ||
        _detNet.load_model([detBin UTF8String]) != 0) {
      NSLog(@"[FBOCREngine] Failed to load detection model");
      _ncnnAvailable = NO;
      self.isModelLoaded = YES;
      return YES;
    }

    if (_recNet.load_param([recParam UTF8String]) != 0 ||
        _recNet.load_model([recBin UTF8String]) != 0) {
      NSLog(@"[FBOCREngine] Failed to load recognition model");
      _ncnnAvailable = NO;
      self.isModelLoaded = YES;
      return YES;
    }

    _ncnnAvailable = YES;
    self.isModelLoaded = YES;
    NSLog(@"[FBOCREngine] NCNN models loaded successfully!");
    return YES;

  } @catch (NSException *exception) {
    NSLog(@"[FBOCREngine] Exception loading models: %@", exception);
    _ncnnAvailable = NO;
    self.isModelLoaded = YES;
    return YES;
  }
}

#pragma mark - Vision API OCR (Fallback)

- (NSArray<FBOCRTextResult *> *)recognizeTextWithVision:(UIImage *)image targetText:(nullable NSString *)targetText {
  if (!image)
    return @[];

  if (@available(iOS 13.0, *)) {
    __block NSMutableArray<FBOCRTextResult *> *results = [NSMutableArray array];

    CGFloat originalPixelWidth = image.CGImage ? CGImageGetWidth(image.CGImage) : image.size.width * image.scale;
    CGFloat originalPixelHeight = image.CGImage ? CGImageGetHeight(image.CGImage) : image.size.height * image.scale;

    UIImage *visionImage = image;
    CGFloat shortSide = MIN(originalPixelWidth, originalPixelHeight);
    
    // [v81] 神级优化：因为 IOSurface 逃生舱取到的是 100% 物理显存原图（比如 750x1334 甚至 1290x2796），
    // 像素面积比以前（被苹果原生 API 降采样的图）大了 4 倍到 9 倍！
    // 传入这么巨大的原生像素图，会导致 A11/A12 芯片的 Vision Accurate 神经网络推理耗时飙升到 4 秒。
    // 因此这里强制将短边大幅压缩到 384px（等效大约 384x682），足够识别除了发丝级别以外的所有清晰字体。
    // [v83修复] 还原安全的 UIGraphics 缩放（CGBitmap 会倒置图像导致 OCR 失明）
    CGFloat maxShortSide = 384.0;
    if (shortSide > maxShortSide) {
        CGFloat ratio = maxShortSide / shortSide;
        CGSize targetSize = CGSizeMake(originalPixelWidth * ratio, originalPixelHeight * ratio);
        
        UIGraphicsBeginImageContextWithOptions(targetSize, NO, 1.0); // 防止二次放大
        [image drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
        visionImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }

    CGImageRef cgImage = visionImage.CGImage;
    if (!cgImage) {
        return @[];
    }

    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc]
        initWithCompletionHandler:^(VNRequest *req, NSError *error) {
          if (error)
            return;

          for (VNRecognizedTextObservation *observation in req.results) {
            VNRecognizedText *topCandidate =
                [observation topCandidates:1].firstObject;
            if (topCandidate) {
              CGRect bbox = observation.boundingBox;
              NSString *recognizedString = topCandidate.string;
              
              // [v86 精确坐标提取]: 如果匹配到了目标字符，尝试获取该子字符串的精确 boundingBox
              if (targetText && targetText.length > 0) {
                  NSRange range = [recognizedString rangeOfString:targetText options:NSCaseInsensitiveSearch];
                  if (range.location != NSNotFound) {
                      NSError *err = nil;
                      VNRectangleObservation *subBboxObs = [topCandidate boundingBoxForRange:range error:&err];
                      if (subBboxObs && !err) {
                          // 如果成功获取到了子字符串的边框，替换原有的整段边框
                          bbox = subBboxObs.boundingBox;
                      }
                  }
              }
              
              CGFloat x = bbox.origin.x * originalPixelWidth;
              CGFloat y = (1 - bbox.origin.y - bbox.size.height) * originalPixelHeight;
              CGFloat w = bbox.size.width * originalPixelWidth;
              CGFloat h = bbox.size.height * originalPixelHeight;

              [results addObject:[FBOCRTextResult
                                     resultWithText:recognizedString
                                              frame:CGRectMake(x, y, w, h)
                                         confidence:topCandidate.confidence]];
            }
          }
        }];

    // 动态智能语言模型分配（大幅降低准确模式下的推理耗时）
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    
    BOOL isAsianText = NO;
    if (targetText && targetText.length > 0) {
        for (NSUInteger i = 0; i < targetText.length; i++) {
            unichar c = [targetText characterAtIndex:i];
            if (c > 0x0500) { // 检测到中/日/韩等宽字符
                isAsianText = YES;
                break;
            }
        }
    }
    
    // 核心优化：如果只需查找英文/拉美文（如 Para ti），绝不加载重达数以百兆计的中文/日文神经网络模型！
    if (isAsianText) {
        request.recognitionLanguages = @[ @"zh-Hans", @"zh-Hant", @"ja-JP", @"ko-KR", @"en-US" ];
    } else {
        request.recognitionLanguages = @[ @"en-US", @"es-ES" ]; // 纯英文或西语
    }
    
    request.usesLanguageCorrection = NO; // 关闭语义修正，加快速度且避免错误联想

    VNImageRequestHandler *handler =
        [[VNImageRequestHandler alloc] initWithCGImage:cgImage options:@{}];
    [handler performRequests:@[ request ] error:nil];

    return results;
  }

  return @[];
}

#pragma mark - NCNN OCR (Primary)

// Detection post-processing structures
struct DetBox {
  std::vector<cv::Point> box;
  float score;
};

// Unclip polygon
static std::vector<cv::Point> unclip(const std::vector<cv::Point> &box,
                                     float unclip_ratio) {
  double area = cv::contourArea(box);
  double length = cv::arcLength(box, true);
  if (length == 0)
    return box;
  double distance = area * unclip_ratio / length;

  cv::RotatedRect rect = cv::minAreaRect(box);
  rect.size.width += (float)(distance * 2);
  rect.size.height += (float)(distance * 2);

  cv::Point2f pts[4];
  rect.points(pts);

  std::vector<cv::Point> ret;
  for (int i = 0; i < 4; i++)
    ret.push_back(cv::Point((int)pts[i].x, (int)pts[i].y));
  return ret;
}

// Filter boxes from NCNN prediction
static std::vector<DetBox> filterBoxes(const ncnn::Mat &pred, float scaleX,
                                       float scaleY, int imgW, int imgH) {
  std::vector<DetBox> results;

  @try {
    int pred_h = pred.h;
    int pred_w = pred.w;

    if (pred_h <= 0 || pred_w <= 0)
      return results;

    const float *data = pred.channel(0);
    cv::Mat floatMap(pred_h, pred_w, CV_32FC1, const_cast<float *>(data));

    cv::Mat binaryMap;
    cv::threshold(floatMap, binaryMap, DET_DB_THRESH, 1.0, cv::THRESH_BINARY);
    binaryMap.convertTo(binaryMap, CV_8UC1, 255);

    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(binaryMap, contours, cv::RETR_LIST,
                     cv::CHAIN_APPROX_SIMPLE);

    for (const auto &contour : contours) {
      if (contour.size() < 3)
        continue;

      cv::RotatedRect rect = cv::minAreaRect(contour);
      float w = rect.size.width;
      float h = rect.size.height;
      if (std::min(w, h) < 3)
        continue;

      cv::Rect bounding = cv::boundingRect(contour);
      bounding.x = std::max(0, bounding.x);
      bounding.y = std::max(0, bounding.y);
      bounding.width = std::min(bounding.width, pred_w - bounding.x);
      bounding.height = std::min(bounding.height, pred_h - bounding.y);

      if (bounding.width <= 0 || bounding.height <= 0)
        continue;

      cv::Mat roi = floatMap(bounding);
      cv::Scalar mean = cv::mean(roi);
      float score = (float)mean[0];
      if (score < DET_DB_BOX_THRESH)
        continue;

      cv::Point2f pts[4];
      rect.points(pts);
      std::vector<cv::Point> box_pts;
      for (int i = 0; i < 4; i++)
        box_pts.push_back(cv::Point((int)pts[i].x, (int)pts[i].y));

      std::vector<cv::Point> expanded = unclip(box_pts, DET_DB_UNCLIP_RATIO);

      std::vector<cv::Point> final_box;
      for (const auto &p : expanded) {
        int ox = std::min(std::max((int)(p.x * scaleX), 0), imgW - 1);
        int oy = std::min(std::max((int)(p.y * scaleY), 0), imgH - 1);
        final_box.push_back(cv::Point(ox, oy));
      }

      DetBox db;
      db.box = final_box;
      db.score = score;
      results.push_back(db);
    }
  } @catch (...) {
    NSLog(@"[FBOCREngine] Exception in filterBoxes");
  }

  return results;
}

- (NSArray<FBOCRTextResult *> *)recognizeTextWithNCNN:(UIImage *)image {
  if (!_ncnnAvailable || !image)
    return @[];

  @try {
    cv::Mat src;
    UIImageToMat(image, src);
    if (src.empty())
      return @[];

    if (src.channels() == 4)
      cv::cvtColor(src, src, cv::COLOR_RGBA2RGB);

    // Preprocess for detection
    int w = src.cols;
    int h = src.rows;
    float ratio = 1.f;
    
    // [v1764] 修复小字漏扫问题：原先使用 max_side 限制在 640，导致竖屏 (例如 1170x2532) 被压成宽仅 295，状态栏小字彻底糊掉
    // 现改为限制短边不能超过 RAW_SHORT_SIDE(640)，或者限制长边在 1280
    int short_side = std::min(w, h);
    if (short_side > RAW_SHORT_SIDE) {
      ratio = (float)RAW_SHORT_SIDE / short_side;
    }

    int resize_w = ((int)(w * ratio) / 32) * 32;
    if (resize_w == 0)
      resize_w = 32;
    int resize_h = ((int)(h * ratio) / 32) * 32;
    if (resize_h == 0)
      resize_h = 32;

    float scale = (float)w / resize_w;

    cv::Mat resized;
    cv::resize(src, resized, cv::Size(resize_w, resize_h));

    ncnn::Mat input = ncnn::Mat::from_pixels(resized.data, ncnn::Mat::PIXEL_RGB,
                                             resized.cols, resized.rows);

    const float mean_vals[3] = {0.485f * 255.f, 0.456f * 255.f, 0.406f * 255.f};
    const float norm_vals[3] = {1.f / (0.229f * 255.f), 1.f / (0.224f * 255.f),
                                1.f / (0.225f * 255.f)};
    input.substract_mean_normalize(mean_vals, norm_vals);

    // Detection
    ncnn::Extractor detEx = _detNet.create_extractor();
    detEx.input("x", input);
    ncnn::Mat detPred;
    detEx.extract("sigmoid_0.tmp_0", detPred);
    if (detPred.empty())
      detEx.extract("maps", detPred);

    if (detPred.empty())
      return @[];

    // Find Boxes
    std::vector<DetBox> boxes =
        filterBoxes(detPred, scale, scale, src.cols, src.rows);

    // Recognition
    NSMutableArray *results = [NSMutableArray array];

    for (const auto &item : boxes) {
      @try {
        cv::Rect rect = cv::boundingRect(item.box);
        rect.x = std::max(0, rect.x);
        rect.y = std::max(0, rect.y);
        rect.width = std::min(rect.width, src.cols - rect.x);
        rect.height = std::min(rect.height, src.rows - rect.y);

        if (rect.width <= 0 || rect.height <= 0)
          continue;

        cv::Mat crop = src(rect).clone();
        float rec_scale = (float)REC_IMG_H / crop.rows;
        int rec_w = (int)(crop.cols * rec_scale);
        if (rec_w <= 0)
          rec_w = 1;
        cv::resize(crop, crop, cv::Size(rec_w, REC_IMG_H));

        ncnn::Mat recInput = ncnn::Mat::from_pixels(
            crop.data, ncnn::Mat::PIXEL_RGB, crop.cols, crop.rows);
        const float rec_mean[3] = {127.5f, 127.5f, 127.5f};
        const float rec_norm[3] = {1 / 127.5f, 1 / 127.5f, 1 / 127.5f};
        recInput.substract_mean_normalize(rec_mean, rec_norm);

        ncnn::Extractor recEx = _recNet.create_extractor();
        recEx.input("x", recInput);
        ncnn::Mat recPred;
        recEx.extract("softmax_0.tmp_0", recPred);

        if (recPred.empty())
          continue;

        // Decode
        std::string text = "";
        int seq_len = recPred.h;
        int num_classes = recPred.w;
        int last_index = -1;

        for (int i = 0; i < seq_len; i++) {
          const float *row = recPred.row(i);
          int max_idx = -1;
          float max_val = -10000.f;
          for (int k = 0; k < num_classes; k++) {
            if (row[k] > max_val) {
              max_val = row[k];
              max_idx = k;
            }
          }
          if (max_idx != last_index && max_idx != 0 &&
              max_idx < (int)_keys.size() && max_idx != num_classes - 1) {
            text += _keys[max_idx];
          }
          last_index = max_idx;
        }

        if (text.length() > 0) {
          [results
              addObject:[FBOCRTextResult
                            resultWithText:
                                [NSString stringWithUTF8String:text.c_str()]
                                     frame:CGRectMake(rect.x, rect.y,
                                                      rect.width, rect.height)
                                confidence:item.score]];
        }
      } @catch (...) {
        continue;
      }
    }

    return results;

  } @catch (NSException *exception) {
    NSLog(@"[FBOCREngine] NCNN OCR failed: %@", exception);
    return @[];
  }
}

#pragma mark - Public API

- (NSArray<FBOCRTextResult *> *)recognizeText:(UIImage *)image {
  if (!image)
    return @[];

  // Try NCNN first, fallback to Vision
  if (_ncnnAvailable) {
    NSArray *results = [self recognizeTextWithNCNN:image];
    if (results.count > 0)
      return results;
  }

  // Fallback to Vision API
  return [self recognizeTextWithVision:image targetText:nil];
}

- (NSArray<FBOCRTextResult *> *)recognizeText:(UIImage *)image
                                     inRegion:(CGRect)region {
  if (!image)
    return @[];

  CGFloat scale = image.scale;
  CGRect cropRect =
      CGRectMake(region.origin.x * scale, region.origin.y * scale,
                 region.size.width * scale, region.size.height * scale);

  CGImageRef croppedRef = CGImageCreateWithImageInRect(image.CGImage, cropRect);
  if (!croppedRef)
    return @[];

  UIImage *croppedImage = [UIImage imageWithCGImage:croppedRef
                                              scale:scale
                                        orientation:image.imageOrientation];
  CGImageRelease(croppedRef);

  NSArray *results = [self recognizeText:croppedImage];

  NSMutableArray *adjustedResults = [NSMutableArray array];
  for (FBOCRTextResult *result in results) {
    CGRect frame = result.frame;
    frame.origin.x += region.origin.x;
    frame.origin.y += region.origin.y;
    result.frame = frame;
    [adjustedResults addObject:result];
  }

  return adjustedResults;
}

- (nullable FBOCRTextResult *)findText:(NSString *)text
                               inImage:(UIImage *)image {
  if (!text || !image)
    return nil;

  // 1. 优先使用极速 Apple Native Vision 引擎（ANE 硬件加速，通常耗时 < 100ms）
  if (@available(iOS 13.0, *)) {
    NSArray<FBOCRTextResult *> *visionResults = [self recognizeTextWithVision:image targetText:text];
    for (FBOCRTextResult *result in visionResults) {
      NSString *cleanResult = [[result.text stringByReplacingOccurrencesOfString:@" " withString:@""] lowercaseString];
      NSString *cleanTarget = [[text stringByReplacingOccurrencesOfString:@" " withString:@""] lowercaseString];
      
      if ([cleanResult containsString:cleanTarget]) {
        NSLog(@"[FBOCREngine] ⚡️ Vision 极速命中: %@", result.text);
        
        // [v87修复]: 移除存在偏差的字符集内插运算（v86中的精确框选已经生效）。
        // 关键：底层返回的是基于原图尺寸绝对物理像素 (Pixels)！而 WDA 点击使用的是逻辑坐标系 (Points)！
        // 必须将其映射回 Point：
        CGFloat screenScale = [UIScreen mainScreen].scale;
        
        CGFloat finalX = result.frame.origin.x / MAX(1.0, screenScale);
        CGFloat finalY = result.frame.origin.y / MAX(1.0, screenScale);
        CGFloat finalW = result.frame.size.width / MAX(1.0, screenScale);
        CGFloat finalH = result.frame.size.height / MAX(1.0, screenScale);
        
        // 确保使用纯净的 target text，并包裹修正后的坐标系
        result.text = text;
        result.frame = CGRectMake(finalX, finalY, finalW, finalH);
        return result;
      }
    }
  }

  // 2. 如果高速的 Vision 没有命中，作为最后保障，启动深度的 NCNN 引擎（耗时 1-2s，适用于特殊字体和复杂排版框选）
  if (_ncnnAvailable) {
    NSLog(@"[FBOCREngine] ⚠️ Vision 未命中目标文字 '%@'，启动深度 NCNN 引擎进行兜底扫描...", text);
    NSArray<FBOCRTextResult *> *ncnnResults = [self recognizeTextWithNCNN:image];
    for (FBOCRTextResult *result in ncnnResults) {
      NSString *cleanResult = [[result.text stringByReplacingOccurrencesOfString:@" " withString:@""] lowercaseString];
      NSString *cleanTarget = [[text stringByReplacingOccurrencesOfString:@" " withString:@""] lowercaseString];
      
      if ([cleanResult containsString:cleanTarget]) {
        NSLog(@"[FBOCREngine] 🐢 NCNN 兜底命中: %@", result.text);
        
        CGFloat screenScale = [UIScreen mainScreen].scale;
        CGFloat finalX = result.frame.origin.x / MAX(1.0, screenScale);
        CGFloat finalY = result.frame.origin.y / MAX(1.0, screenScale);
        CGFloat finalW = result.frame.size.width / MAX(1.0, screenScale);
        CGFloat finalH = result.frame.size.height / MAX(1.0, screenScale);
        
        result.text = text;
        result.frame = CGRectMake(finalX, finalY, finalW, finalH);
        return result;
      }
    }
  }

  return nil;
}

#pragma mark - Find Image (OpenCV Template Matching - Multi Strategy)

/// 内部辅助：在给定的灰度图和模板上执行单尺度模板匹配
/// @param imgGray   大图灰度
/// @param tmplGray  模板灰度
/// @param mask      遮罩（可为空）
/// @param bestVal   当前最优置信度（传入/传出）
/// @param bestLoc   当前最优位置（传入/传出）
/// @param bestW     最优匹配宽度（传入/传出）
/// @param bestH     最优匹配高度（传入/传出）
static void matchAtScale(const cv::Mat &imgGray,
                         const cv::Mat &tmplGray,
                         const cv::Mat &mask,
                         double &bestVal,
                         cv::Point &bestLoc,
                         int &bestW, int &bestH) {
  int rCols = imgGray.cols - tmplGray.cols + 1;
  int rRows = imgGray.rows - tmplGray.rows + 1;
  if (rCols <= 0 || rRows <= 0) return;

  cv::Mat result;
  if (!mask.empty()) {
    cv::matchTemplate(imgGray, tmplGray, result,
                      cv::TM_CCOEFF_NORMED, mask);
  } else {
    cv::matchTemplate(imgGray, tmplGray, result,
                      cv::TM_CCOEFF_NORMED);
  }

  double minVal, maxVal;
  cv::Point minLoc, maxLoc;
  cv::minMaxLoc(result, &minVal, &maxVal, &minLoc, &maxLoc);

  if (maxVal > bestVal) {
    bestVal = maxVal;
    bestLoc = maxLoc;
    bestW = tmplGray.cols;
    bestH = tmplGray.rows;
  }
}

- (NSDictionary *)findImage:(UIImage *)templateImage
                    inImage:(UIImage *)targetImage
                  threshold:(float)threshold {
  if (!templateImage || !targetImage) {
    return @{@"found" : @NO, @"error" : @"Missing images"};
  }

  @try {
    cv::Mat tmpl, img;
    UIImageToMat(templateImage, tmpl);
    UIImageToMat(targetImage, img);

    if (tmpl.empty() || img.empty()) {
      return @{@"found" : @NO, @"error" : @"Failed to convert images"};
    }

    // =========== 准备阶段 ===========
    // 目标大图 → 灰度
    cv::Mat imgGray;
    if (img.channels() == 4)
      cv::cvtColor(img, imgGray, cv::COLOR_RGBA2GRAY);
    else if (img.channels() == 3)
      cv::cvtColor(img, imgGray, cv::COLOR_RGB2GRAY);
    else
      imgGray = img;

    // 模板 → 灰度 + 可选 Alpha 遮罩
    cv::Mat tmplGray, alphaMask;
    bool hasAlpha = false;

    if (tmpl.channels() == 4) {
      std::vector<cv::Mat> channels;
      cv::split(tmpl, channels);
      alphaMask = channels[3];
      cv::threshold(alphaMask, alphaMask, 128, 255, cv::THRESH_BINARY);

      // 判断是否真的有透明区域（如果 Alpha 全是 255 则没有实际遮罩）
      int nonZero = cv::countNonZero(alphaMask);
      int total = alphaMask.rows * alphaMask.cols;
      hasAlpha = (nonZero < total * 0.98); // 超过 2% 的像素是透明的才算有遮罩

      cv::cvtColor(tmpl, tmplGray, cv::COLOR_RGBA2GRAY);
    } else if (tmpl.channels() == 3) {
      cv::cvtColor(tmpl, tmplGray, cv::COLOR_RGB2GRAY);
    } else {
      tmplGray = tmpl;
    }

    double bestVal = -1.0;
    cv::Point bestLoc;
    int bestW = 0, bestH = 0;

    // =========== 策略 1：Alpha 遮罩匹配 ===========
    if (hasAlpha) {
      matchAtScale(imgGray, tmplGray, alphaMask,
                   bestVal, bestLoc, bestW, bestH);
      if (bestVal >= threshold) {
        return @{
          @"found" : @YES,
          @"confidence" : @(bestVal),
          @"x" : @(bestLoc.x),
          @"y" : @(bestLoc.y),
          @"width" : @(bestW),
          @"height" : @(bestH)
        };
      }
    }

    // =========== 策略 2：普通灰度匹配 ===========
    cv::Mat emptyMask;
    matchAtScale(imgGray, tmplGray, emptyMask,
                 bestVal, bestLoc, bestW, bestH);

    if (bestVal >= threshold) {
      // 精度无损早退：置信度已达标，直接返回，跳过最耗时的 Canny 边缘匹配
      return @{
        @"found" : @YES,
        @"confidence" : @(bestVal),
        @"x" : @(bestLoc.x),
        @"y" : @(bestLoc.y),
        @"width" : @(bestW),
        @"height" : @(bestH)
      };
    }

    // =========== 策略 2.5：黑白通道隔离匹配 ===========
    // 针对白色/黑色图标叠加在动态视频背景上的场景
    // 原理：将模板和大图做同方向阈值二值化，只保留极亮/极暗像素为前景
    //       背景颜色变化对二值图无影响，从而实现稳定匹配
    {
      int totalPx = tmplGray.rows * tmplGray.cols;
      if (totalPx > 0) {
        // 统计模板中亮像素（接近纯白）和暗像素（接近纯黑）的占比
        cv::Mat brightMask, darkMask;
        cv::threshold(tmplGray, brightMask, 200, 255, cv::THRESH_BINARY);
        cv::threshold(tmplGray, darkMask, 55, 255, cv::THRESH_BINARY_INV);

        float brightRatio = (float)cv::countNonZero(brightMask) / totalPx;
        float darkRatio   = (float)cv::countNonZero(darkMask) / totalPx;

        // ---- 白色主导 (≥15% 像素接近纯白) ----
        if (brightRatio >= 0.15f) {
          cv::Mat imgBin, tmplBin;
          cv::threshold(imgGray, imgBin, 200, 255, cv::THRESH_BINARY);
          tmplBin = brightMask; // 已经算好了，直接复用
          matchAtScale(imgBin, tmplBin, emptyMask,
                       bestVal, bestLoc, bestW, bestH);
          if (bestVal >= threshold) {
            return @{
              @"found" : @YES,
              @"confidence" : @(bestVal),
              @"x" : @(bestLoc.x),
              @"y" : @(bestLoc.y),
              @"width" : @(bestW),
              @"height" : @(bestH)
            };
          }
        }

        // ---- 黑色主导 (≥15% 像素接近纯黑) ----
        if (darkRatio >= 0.15f) {
          cv::Mat imgBin, tmplBin;
          cv::threshold(imgGray, imgBin, 55, 255, cv::THRESH_BINARY_INV);
          tmplBin = darkMask; // 已经算好了，直接复用
          matchAtScale(imgBin, tmplBin, emptyMask,
                       bestVal, bestLoc, bestW, bestH);
          if (bestVal >= threshold) {
            return @{
              @"found" : @YES,
              @"confidence" : @(bestVal),
              @"x" : @(bestLoc.x),
              @"y" : @(bestLoc.y),
              @"width" : @(bestW),
              @"height" : @(bestH)
            };
          }
        }
      }
    }

    // =========== 策略 3：Canny 边缘匹配 ===========
    // 将大图和模板都转成边缘图，只比较线条轮廓
    // 这样箭头等形状无论背景是什么颜色都能匹配
    {
      cv::Mat imgEdge, tmplEdge;

      // 对大图做模糊降噪 + Canny 边缘检测
      cv::GaussianBlur(imgGray, imgEdge, cv::Size(3, 3), 0);
      cv::Canny(imgEdge, imgEdge, 50, 150);

      // 对模板做同样处理
      cv::GaussianBlur(tmplGray, tmplEdge, cv::Size(3, 3), 0);
      cv::Canny(tmplEdge, tmplEdge, 50, 150);

      // 多尺度边缘匹配：原始 + ±5%、±10%
      float scales[] = {1.0f, 0.95f, 1.05f, 0.90f, 1.10f};
      double firstScaleVal = -1.0; // 记录第一个尺度的置信度
      for (int s = 0; s < 5; s++) {
        float sc = scales[s];
        cv::Mat scaledEdge;

        if (std::abs(sc - 1.0f) < 0.001f) {
          scaledEdge = tmplEdge;
        } else {
          // 智能早退：如果第一个尺度(1.0x)的置信度极低，后续尺度也不太可能有好结果
          if (firstScaleVal >= 0 && firstScaleVal < 0.3) break;
          int nw = (int)(tmplEdge.cols * sc);
          int nh = (int)(tmplEdge.rows * sc);
          if (nw <= 0 || nh <= 0) continue;
          cv::resize(tmplEdge, scaledEdge, cv::Size(nw, nh));
        }

        double prevBest = bestVal;
        matchAtScale(imgEdge, scaledEdge, emptyMask,
                     bestVal, bestLoc, bestW, bestH);

        // 记录第一个尺度的置信度
        if (s == 0) firstScaleVal = bestVal;

        if (bestVal >= 0.95) break; // 高置信度提前退出
      }
    }

    if (bestVal >= threshold) {
      return @{
        @"found" : @YES,
        @"confidence" : @(bestVal),
        @"x" : @(bestLoc.x),
        @"y" : @(bestLoc.y),
        @"width" : @(bestW),
        @"height" : @(bestH)
      };
    }

    return @{@"found" : @NO, @"confidence" : @(bestVal)};

  } @catch (NSException *exception) {
    NSLog(@"[FBOCREngine] findImage failed: %@", exception);
    return @{@"found" : @NO, @"error" : [exception description]};
  }
}

@end
