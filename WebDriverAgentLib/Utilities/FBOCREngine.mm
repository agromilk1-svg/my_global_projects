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
static const int RAW_SHORT_SIDE = 960;
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
    _opt.num_threads = 2;
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

- (NSArray<FBOCRTextResult *> *)recognizeTextWithVision:(UIImage *)image {
  if (!image)
    return @[];

  if (@available(iOS 13.0, *)) {
    __block NSMutableArray<FBOCRTextResult *> *results = [NSMutableArray array];

    CGImageRef cgImage = image.CGImage;
    if (!cgImage)
      return @[];

    CGFloat imageWidth = CGImageGetWidth(cgImage);
    CGFloat imageHeight = CGImageGetHeight(cgImage);

    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc]
        initWithCompletionHandler:^(VNRequest *req, NSError *error) {
          if (error)
            return;

          for (VNRecognizedTextObservation *observation in req.results) {
            VNRecognizedText *topCandidate =
                [observation topCandidates:1].firstObject;
            if (topCandidate) {
              CGRect bbox = observation.boundingBox;
              CGFloat x = bbox.origin.x * imageWidth;
              CGFloat y = (1 - bbox.origin.y - bbox.size.height) * imageHeight;
              CGFloat w = bbox.size.width * imageWidth;
              CGFloat h = bbox.size.height * imageHeight;

              [results addObject:[FBOCRTextResult
                                     resultWithText:topCandidate.string
                                              frame:CGRectMake(x, y, w, h)
                                         confidence:topCandidate.confidence]];
            }
          }
        }];

    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.recognitionLanguages = @[ @"zh-Hans", @"en-US" ];
    request.usesLanguageCorrection = YES;

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
    int max_side = std::max(w, h);
    if (max_side > RAW_SHORT_SIDE) {
      ratio = (float)RAW_SHORT_SIDE / max_side;
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
  return [self recognizeTextWithVision:image];
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

  NSArray<FBOCRTextResult *> *results = [self recognizeText:image];

  for (FBOCRTextResult *result in results) {
    if ([result.text containsString:text]) {
      return result;
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
      return @{
        @"found" : @YES,
        @"confidence" : @(bestVal),
        @"x" : @(bestLoc.x),
        @"y" : @(bestLoc.y),
        @"width" : @(bestW),
        @"height" : @(bestH)
      };
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
      for (int s = 0; s < 5; s++) {
        float sc = scales[s];
        cv::Mat scaledEdge;

        if (std::abs(sc - 1.0f) < 0.001f) {
          scaledEdge = tmplEdge;
        } else {
          int nw = (int)(tmplEdge.cols * sc);
          int nh = (int)(tmplEdge.rows * sc);
          if (nw <= 0 || nh <= 0) continue;
          cv::resize(tmplEdge, scaledEdge, cv::Size(nw, nh));
        }

        matchAtScale(imgEdge, scaledEdge, emptyMask,
                     bestVal, bestLoc, bestW, bestH);

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
