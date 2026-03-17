/**
 * ECWDA Extended Commands
 * 扩展功能命令 - 包含找色、OCR、长按、双击等功能
 */

#import "FBECWDACommands.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CommonCrypto/CommonDigest.h>
#import <Photos/Photos.h>
#import <Vision/Vision.h>
#import <XCTest/XCTest.h>

#import "FBConfiguration.h"
#import "FBOCREngine.h"
#import "FBResponsePayload.h"
#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBRunLoopSpinner.h"
#import "FBScreenshot.h"
#import "FBSession.h"
#import "FBTouchMonitor.h"
#import "FBUnattachedAppLauncher.h"
#import "FBXCTestDaemonsProxy.h"
#import "FBXCodeCompatibility.h"
#import "XCEventGenerator.h"
#import "XCPointerEventPath.h"
#import "XCSynthesizedEventRecord.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIElement+FBFind.h"
#import "XCUIElement+FBTyping.h"


// ECMAIN 在线状态标志
static BOOL _isEcmainOnline = YES;

@implementation FBECWDACommands

#pragma mark - 保活探测 (ECWDA → ECMAIN via 8089)

+ (void)load {
  // 延迟 10 秒启动保活定时器，等待网络栈就绪
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   [self startEcmainKeepAliveTimer];
                 });
}

+ (void)startEcmainKeepAliveTimer {
  // 每 60 秒探测 ECMAIN 的 8089 端口是否存活
  [NSTimer scheduledTimerWithTimeInterval:60.0
                                  repeats:YES
                                    block:^(NSTimer *_Nonnull timer) {
                                      [self checkEcmainAlive];
                                    }];
  // 首次立即执行一次
  [self checkEcmainAlive];
  NSLog(@"[ECWDA] 保活探测已启动: 每 60 秒检测 ECMAIN (127.0.0.1:8089)");
}

+ (void)checkEcmainAlive {
  NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:8089/"];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.timeoutInterval = 60.0;
  req.HTTPMethod = @"GET";

  [[NSURLSession.sharedSession
      dataTaskWithRequest:req
        completionHandler:^(NSData *_Nullable data,
                            NSURLResponse *_Nullable response,
                            NSError *_Nullable error) {
          NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
          if (error || httpResp.statusCode == 0) {
            BOOL wasOnline = _isEcmainOnline;
            _isEcmainOnline = NO;
            NSLog(@"[ECWDA] ⚠️ ECMAIN 进程离线 (8089 端口无响应)");
            // 如果之前在线，现在离线，则尝试拉起 ECMAIN
            if (wasOnline) {
              dispatch_async(dispatch_get_main_queue(), ^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(5.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                                 NSLog(@"[ECWDA] 🔄 正在尝试拉起 ECMAIN...");
                                 BOOL launched = [FBUnattachedAppLauncher
                                     launchAppWithBundleId:@"com.ecmain.app"];
                                 if (launched) {
                                   NSLog(@"[ECWDA] ✅ ECMAIN 已自动拉起");
                                 } else {
                                   NSLog(@"[ECWDA] ❌ ECMAIN 拉起失败");
                                 }
                               });
              });
            }
          } else {
            if (!_isEcmainOnline) {
              NSLog(@"[ECWDA] ✅ ECMAIN 进程已恢复在线");
            }
            _isEcmainOnline = YES;
          }
        }] resume];
}

+ (BOOL)isEcmainOnline {
  return _isEcmainOnline;
}

#pragma mark - Routes

+ (NSArray *)routes {
  return @[
    // 设备信息
    [[FBRoute GET:@"/wda/ecwda/info"].withoutSession
        respondWithTarget:self
                   action:@selector(handleGetInfo:)],

    // 坐标点击
    [[FBRoute POST:@"/wda/tapByCoord"].withoutSession
        respondWithTarget:self
                   action:@selector(handleTapByCoord:)],

    // 找色功能
    [[FBRoute POST:@"/wda/findColor"].withoutSession
        respondWithTarget:self
                   action:@selector(handleFindColor:)],

    // 多点找色
    [[FBRoute POST:@"/wda/findMultiColor"].withoutSession
        respondWithTarget:self
                   action:@selector(handleFindMultiColor:)],

    // 比色
    [[FBRoute POST:@"/wda/cmpColor"].withoutSession
        respondWithTarget:self
                   action:@selector(handleCmpColor:)],

    // 获取像素颜色
    [[FBRoute POST:@"/wda/pixel"].withoutSession
        respondWithTarget:self
                   action:@selector(handleGetPixel:)],

    // OCR 识别 (兼容 easyclick)
    [[FBRoute POST:@"/wda/ocr"].withoutSession
        respondWithTarget:self
                   action:@selector(handleOCR:)],

    // 查找文字 (兼容 easyclick)
    [[FBRoute POST:@"/wda/findText"].withoutSession
        respondWithTarget:self
                   action:@selector(handleFindText:)],

    // 找图
    [[FBRoute POST:@"/wda/findImage"].withoutSession
        respondWithTarget:self
                   action:@selector(handleFindImage:)],

    // 长按
    [[FBRoute POST:@"/wda/longPress"].withoutSession
        respondWithTarget:self
                   action:@selector(handleLongPress:)],

    // 坐标滑动（无需 session）
    [[FBRoute POST:@"/wda/swipeByCoord"].withoutSession
        respondWithTarget:self
                   action:@selector(handleSwipeByCoord:)],

    // 双击
    [[FBRoute POST:@"/wda/doubleTap"].withoutSession
        respondWithTarget:self
                   action:@selector(handleDoubleTap:)],

    // 文字查找点击
    [[FBRoute POST:@"/wda/clickText"].withoutSession
        respondWithTarget:self
                   action:@selector(handleClickText:)],

    // 工具函数 - 随机数
    [[FBRoute POST:@"/wda/utils/random"].withoutSession
        respondWithTarget:self
                   action:@selector(handleRandom:)],

    // 工具函数 - MD5
    [[FBRoute POST:@"/wda/utils/md5"].withoutSession
        respondWithTarget:self
                   action:@selector(handleMD5:)],

    // 脚本执行
    [[FBRoute POST:@"/wda/script/execute"].withoutSession
        respondWithTarget:self
                   action:@selector(handleScriptExecute:)],

    // 二维码识别
    [[FBRoute POST:@"/wda/qrcode/scan"].withoutSession
        respondWithTarget:self
                   action:@selector(handleQRCodeScan:)],

    // 剪贴板操作
    [[FBRoute GET:@"/wda/clipboard/get"].withoutSession
        respondWithTarget:self
                   action:@selector(handleClipboardGet:)],
    [[FBRoute POST:@"/wda/clipboard/set"].withoutSession
        respondWithTarget:self
                   action:@selector(handleClipboardSet:)],

    // 文本输入
    [[FBRoute POST:@"/wda/inputText"].withoutSession
        respondWithTarget:self
                   action:@selector(handleInputText:)],

    // 打开 URL
    [[FBRoute POST:@"/wda/openUrl"].withoutSession
        respondWithTarget:self
                   action:@selector(handleOpenUrl:)],

    // 节点查找
    [[FBRoute POST:@"/wda/node/findByText"].withoutSession
        respondWithTarget:self
                   action:@selector(handleNodeFindByText:)],
    [[FBRoute POST:@"/wda/node/findByType"].withoutSession
        respondWithTarget:self
                   action:@selector(handleNodeFindByType:)],
    [[FBRoute GET:@"/wda/node/all"].withoutSession
        respondWithTarget:self
                   action:@selector(handleNodeGetAll:)],
    [[FBRoute POST:@"/wda/node/click"].withoutSession
        respondWithTarget:self
                   action:@selector(handleNodeClick:)],

    // Base64 编解码
    [[FBRoute POST:@"/wda/utils/base64/encode"].withoutSession
        respondWithTarget:self
                   action:@selector(handleBase64Encode:)],
    [[FBRoute POST:@"/wda/utils/base64/decode"].withoutSession
        respondWithTarget:self
                   action:@selector(handleBase64Decode:)],

    // 震动
    [[FBRoute POST:@"/wda/utils/vibrate"].withoutSession
        respondWithTarget:self
                   action:@selector(handleVibrate:)],

    // 保存到相册
    [[FBRoute POST:@"/wda/utils/saveToAlbum"].withoutSession
        respondWithTarget:self
                   action:@selector(handleSaveToAlbum:)],

    // 应用信息
    [[FBRoute GET:@"/wda/app/info"].withoutSession
        respondWithTarget:self
                   action:@selector(handleAppInfo:)],

    // 触摸事件监听
    [[FBRoute POST:@"/wda/touch/start"].withoutSession
        respondWithTarget:self
                   action:@selector(handleTouchStart:)],
    [[FBRoute POST:@"/wda/touch/stop"].withoutSession
        respondWithTarget:self
                   action:@selector(handleTouchStop:)],
    [[FBRoute GET:@"/wda/touch/events"].withoutSession
        respondWithTarget:self
                   action:@selector(handleTouchEvents:)],
  ];
}

#pragma mark - Info

+ (id<FBResponsePayload>)handleGetInfo:(FBRouteRequest *)request {
  return FBResponseWithObject(@{
    @"version" : @"1.0.0",
    @"name" : @"ECWDA",
    @"features" : @[
      @"findColor", @"multiColor", @"cmpColor", @"pixel", @"ocr", @"longPress",
      @"doubleTap", @"clickText", @"scriptExecute", @"qrcode", @"clipboard",
      @"inputText", @"openUrl", @"nodeFind", @"base64", @"vibrate",
      @"saveToAlbum", @"appInfo"
    ]
  });
}

#pragma mark - Color Finding

+ (id<FBResponsePayload>)handleFindColor:(FBRouteRequest *)request {
  NSString *colorStr = request.arguments[@"color"];
  NSDictionary *region = request.arguments[@"region"];
  NSNumber *similarity = request.arguments[@"similarity"] ?: @(0.9);

  if (!colorStr) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"color is required"
                              traceback:nil]);
  }

  // 获取截图
  NSError *error;
  NSData *screenshotData =
      [FBScreenshot takeInOriginalResolutionWithQuality:2 error:&error];
  if (!screenshotData) {
    return FBResponseWithUnknownError(error);
  }

  UIImage *screenshot = [UIImage imageWithData:screenshotData];
  CGImageRef imageRef = screenshot.CGImage;

  // 解析目标颜色
  NSInteger targetColor = [self parseColor:colorStr];
  NSInteger targetR = (targetColor >> 16) & 0xFF;
  NSInteger targetG = (targetColor >> 8) & 0xFF;
  NSInteger targetB = targetColor & 0xFF;

  // 搜索区域
  CGFloat scale = [UIScreen mainScreen].scale;
  CGFloat startX = 0, startY = 0;
  CGFloat endX = CGImageGetWidth(imageRef);
  CGFloat endY = CGImageGetHeight(imageRef);

  if (region) {
    startX = [region[@"x"] floatValue] * scale;
    startY = [region[@"y"] floatValue] * scale;
    endX = startX + [region[@"width"] floatValue] * scale;
    endY = startY + [region[@"height"] floatValue] * scale;
  }

  // 获取像素数据
  CFDataRef pixelData =
      CGDataProviderCopyData(CGImageGetDataProvider(imageRef));
  const UInt8 *data = CFDataGetBytePtr(pixelData);
  size_t bytesPerRow = CGImageGetBytesPerRow(imageRef);
  size_t bytesPerPixel = CGImageGetBitsPerPixel(imageRef) / 8;

  CGFloat sim = similarity.floatValue;
  NSInteger tolerance = (NSInteger)((1.0 - sim) * 255 * 3);

  // 搜索颜色
  for (NSInteger y = (NSInteger)startY; y < (NSInteger)endY; y++) {
    for (NSInteger x = (NSInteger)startX; x < (NSInteger)endX; x++) {
      NSInteger offset = y * bytesPerRow + x * bytesPerPixel;
      NSInteger r = data[offset];
      NSInteger g = data[offset + 1];
      NSInteger b = data[offset + 2];

      NSInteger diff = abs((int)(r - targetR)) + abs((int)(g - targetG)) +
                       abs((int)(b - targetB));
      if (diff <= tolerance) {
        CFRelease(pixelData);
        return FBResponseWithObject(
            @{@"x" : @(x / scale), @"y" : @(y / scale), @"found" : @YES});
      }
    }
  }

  CFRelease(pixelData);
  return FBResponseWithObject(@{@"x" : @(-1), @"y" : @(-1), @"found" : @NO});
}

+ (id<FBResponsePayload>)handleFindMultiColor:(FBRouteRequest *)request {
  NSString *firstColor = request.arguments[@"firstColor"];
  NSArray *offsetColors = request.arguments[@"offsetColors"];
  NSDictionary *region = request.arguments[@"region"];
  NSNumber *similarity = request.arguments[@"similarity"] ?: @(0.9);

  if (!firstColor || !offsetColors) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:
            @"firstColor and offsetColors are required"
                              traceback:nil]);
  }

  // 获取截图
  NSError *error;
  NSData *screenshotData =
      [FBScreenshot takeInOriginalResolutionWithQuality:2 error:&error];
  if (!screenshotData) {
    return FBResponseWithUnknownError(error);
  }

  UIImage *screenshot = [UIImage imageWithData:screenshotData];
  CGImageRef imageRef = screenshot.CGImage;

  NSInteger firstColorVal = [self parseColor:firstColor];
  NSInteger firstR = (firstColorVal >> 16) & 0xFF;
  NSInteger firstG = (firstColorVal >> 8) & 0xFF;
  NSInteger firstB = firstColorVal & 0xFF;

  CGFloat startX = 0, startY = 0;
  CGFloat endX = CGImageGetWidth(imageRef);
  CGFloat endY = CGImageGetHeight(imageRef);

  if (region) {
    startX = [region[@"x"] floatValue];
    startY = [region[@"y"] floatValue];
    endX = startX + [region[@"width"] floatValue];
    endY = startY + [region[@"height"] floatValue];
  }

  CFDataRef pixelData =
      CGDataProviderCopyData(CGImageGetDataProvider(imageRef));
  const UInt8 *data = CFDataGetBytePtr(pixelData);
  size_t bytesPerRow = CGImageGetBytesPerRow(imageRef);
  size_t bytesPerPixel = CGImageGetBitsPerPixel(imageRef) / 8;
  size_t width = CGImageGetWidth(imageRef);
  size_t height = CGImageGetHeight(imageRef);

  CGFloat sim = similarity.floatValue;
  NSInteger tolerance = (NSInteger)((1.0 - sim) * 255 * 3);

  for (NSInteger y = (NSInteger)startY; y < (NSInteger)endY; y++) {
    for (NSInteger x = (NSInteger)startX; x < (NSInteger)endX; x++) {
      NSInteger offset = y * bytesPerRow + x * bytesPerPixel;
      NSInteger r = data[offset];
      NSInteger g = data[offset + 1];
      NSInteger b = data[offset + 2];

      NSInteger diff = abs((int)(r - firstR)) + abs((int)(g - firstG)) +
                       abs((int)(b - firstB));
      if (diff > tolerance)
        continue;

      // 检查偏移颜色
      BOOL allMatch = YES;
      for (NSDictionary *offsetColor in offsetColors) {
        NSInteger ox = [offsetColor[@"offsetX"] integerValue];
        NSInteger oy = [offsetColor[@"offsetY"] integerValue];
        NSString *colorHex = offsetColor[@"color"];

        NSInteger checkX = x + ox;
        NSInteger checkY = y + oy;

        if (checkX < 0 || checkX >= (NSInteger)width || checkY < 0 ||
            checkY >= (NSInteger)height) {
          allMatch = NO;
          break;
        }

        NSInteger checkOffset = checkY * bytesPerRow + checkX * bytesPerPixel;
        NSInteger checkR = data[checkOffset];
        NSInteger checkG = data[checkOffset + 1];
        NSInteger checkB = data[checkOffset + 2];

        NSInteger targetColorVal = [self parseColor:colorHex];
        NSInteger targetR = (targetColorVal >> 16) & 0xFF;
        NSInteger targetG = (targetColorVal >> 8) & 0xFF;
        NSInteger targetB = targetColorVal & 0xFF;

        NSInteger checkDiff = abs((int)(checkR - targetR)) +
                              abs((int)(checkG - targetG)) +
                              abs((int)(checkB - targetB));
        if (checkDiff > tolerance) {
          allMatch = NO;
          break;
        }
      }

      if (allMatch) {
        CFRelease(pixelData);
        return FBResponseWithObject(
            @{@"x" : @(x), @"y" : @(y), @"found" : @YES});
      }
    }
  }

  CFRelease(pixelData);
  return FBResponseWithObject(@{@"x" : @(-1), @"y" : @(-1), @"found" : @NO});
}

+ (id<FBResponsePayload>)handleCmpColor:(FBRouteRequest *)request {
  NSNumber *xNum = request.arguments[@"x"];
  NSNumber *yNum = request.arguments[@"y"];
  NSString *colorStr = request.arguments[@"color"];
  NSNumber *similarity = request.arguments[@"similarity"] ?: @(0.9);

  if (!xNum || !yNum || !colorStr) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"x, y and color are required"
                              traceback:nil]);
  }

  NSError *error;
  NSData *screenshotData =
      [FBScreenshot takeInOriginalResolutionWithQuality:2 error:&error];
  if (!screenshotData) {
    return FBResponseWithUnknownError(error);
  }

  UIImage *screenshot = [UIImage imageWithData:screenshotData];
  CGImageRef imageRef = screenshot.CGImage;

  CGFloat scale = [UIScreen mainScreen].scale;
  NSInteger x = (NSInteger)(xNum.doubleValue * scale);
  NSInteger y = (NSInteger)(yNum.doubleValue * scale);

  CFDataRef pixelData =
      CGDataProviderCopyData(CGImageGetDataProvider(imageRef));
  const UInt8 *data = CFDataGetBytePtr(pixelData);
  size_t bytesPerRow = CGImageGetBytesPerRow(imageRef);
  size_t bytesPerPixel = CGImageGetBitsPerPixel(imageRef) / 8;

  NSInteger offset = y * bytesPerRow + x * bytesPerPixel;
  NSInteger r = data[offset];
  NSInteger g = data[offset + 1];
  NSInteger b = data[offset + 2];

  CFRelease(pixelData);

  NSInteger targetColor = [self parseColor:colorStr];
  NSInteger targetR = (targetColor >> 16) & 0xFF;
  NSInteger targetG = (targetColor >> 8) & 0xFF;
  NSInteger targetB = targetColor & 0xFF;

  CGFloat sim = similarity.floatValue;
  NSInteger tolerance = (NSInteger)((1.0 - sim) * 255 * 3);
  NSInteger diff = abs((int)(r - targetR)) + abs((int)(g - targetG)) +
                   abs((int)(b - targetB));

  return FBResponseWithObject(
      @{@"match" : @(diff <= tolerance), @"diff" : @(diff)});
}

+ (id<FBResponsePayload>)handleGetPixel:(FBRouteRequest *)request {
  NSNumber *xNum = request.arguments[@"x"];
  NSNumber *yNum = request.arguments[@"y"];

  if (!xNum || !yNum) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"x and y are required"
                              traceback:nil]);
  }

  NSError *error;
  NSData *screenshotData =
      [FBScreenshot takeInOriginalResolutionWithQuality:2 error:&error];
  if (!screenshotData) {
    return FBResponseWithUnknownError(error);
  }

  UIImage *screenshot = [UIImage imageWithData:screenshotData];
  CGImageRef imageRef = screenshot.CGImage;

  CGFloat scale = [UIScreen mainScreen].scale;
  NSInteger x = (NSInteger)(xNum.doubleValue * scale);
  NSInteger y = (NSInteger)(yNum.doubleValue * scale);

  CFDataRef pixelData =
      CGDataProviderCopyData(CGImageGetDataProvider(imageRef));
  const UInt8 *data = CFDataGetBytePtr(pixelData);
  size_t bytesPerRow = CGImageGetBytesPerRow(imageRef);
  size_t bytesPerPixel = CGImageGetBitsPerPixel(imageRef) / 8;

  NSInteger offset = y * bytesPerRow + x * bytesPerPixel;
  NSInteger r = data[offset];
  NSInteger g = data[offset + 1];
  NSInteger b = data[offset + 2];

  CFRelease(pixelData);

  NSString *hex = [NSString
      stringWithFormat:@"#%02lX%02lX%02lX", (long)r, (long)g, (long)b];
  NSInteger colorInt = (r << 16) | (g << 8) | b;

  return FBResponseWithObject(@{
    @"color" : hex,
    @"value" : @(colorInt),
    @"r" : @(r),
    @"g" : @(g),
    @"b" : @(b)
  });
}

#pragma mark - OCR

+ (id<FBResponsePayload>)handleOCR:(FBRouteRequest *)request {
  // Use FBOCREngine (NCNN + OpenCV)
  NSError *error;
  NSData *screenshotData =
      [FBScreenshot takeInOriginalResolutionWithQuality:2 error:&error];
  if (!screenshotData) {
    return FBResponseWithUnknownError(error);
  }
  UIImage *screenshot = [UIImage imageWithData:screenshotData];

  NSArray<FBOCRTextResult *> *results;
  NSDictionary *regionDict = request.arguments[@"region"];
  CGFloat scale = [UIScreen mainScreen].scale;
  if (regionDict) {
    CGRect region = CGRectMake([regionDict[@"x"] doubleValue] * scale,
                               [regionDict[@"y"] doubleValue] * scale,
                               [regionDict[@"width"] doubleValue] * scale,
                               [regionDict[@"height"] doubleValue] * scale);
    results = [[FBOCREngine sharedEngine] recognizeText:screenshot
                                               inRegion:region];
  } else {
    results = [[FBOCREngine sharedEngine] recognizeText:screenshot];
  }

  NSMutableArray *jsonResults = [NSMutableArray array];
  for (FBOCRTextResult *res in results) {
    CGRect f = res.frame;
    res.frame = CGRectMake(f.origin.x / scale, f.origin.y / scale,
                           f.size.width / scale, f.size.height / scale);
    [jsonResults addObject:[res toDictionary]];
  }

  return FBResponseWithObject(@{@"texts" : jsonResults});
}

+ (id<FBResponsePayload>)handleFindText:(FBRouteRequest *)request {
  NSString *text = request.arguments[@"text"];
  if (!text) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"Missing 'text' parameter"
                              traceback:nil]);
  }

  NSError *error;
  NSData *screenshotData =
      [FBScreenshot takeInOriginalResolutionWithQuality:2 error:&error];
  if (!screenshotData) {
    return FBResponseWithUnknownError(error);
  }
  UIImage *screenshot = [UIImage imageWithData:screenshotData];

  FBOCRTextResult *result = [[FBOCREngine sharedEngine] findText:text
                                                         inImage:screenshot];

  if (result) {
    CGFloat scale = [UIScreen mainScreen].scale;
    CGRect f = result.frame;
    result.frame = CGRectMake(f.origin.x / scale, f.origin.y / scale,
                              f.size.width / scale, f.size.height / scale);
    return FBResponseWithObject(
        @{@"found" : @YES, @"result" : [result toDictionary]});
  } else {
    return FBResponseWithObject(@{@"found" : @NO});
  }
}

+ (id<FBResponsePayload>)handleFindImage:(FBRouteRequest *)request {
  NSString *templateBase64 = request.arguments[@"template"];
  NSNumber *threshold = request.arguments[@"threshold"] ?: @(0.8);

  if (!templateBase64) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"Missing 'template' parameter (base64)"
                              traceback:nil]);
  }

  NSData *templateData = [[NSData alloc]
      initWithBase64EncodedString:templateBase64
                          options:NSDataBase64DecodingIgnoreUnknownCharacters];
  UIImage *templateImage = [UIImage imageWithData:templateData];
  if (!templateImage) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"Invalid template image data"
                              traceback:nil]);
  }

  NSError *error;
  NSData *screenshotData =
      [FBScreenshot takeInOriginalResolutionWithQuality:2 error:&error];
  if (!screenshotData) {
    return FBResponseWithUnknownError(error);
  }
  UIImage *screenshot = [UIImage imageWithData:screenshotData];

  NSDictionary *result =
      [[FBOCREngine sharedEngine] findImage:templateImage
                                    inImage:screenshot
                                  threshold:threshold.floatValue];

  if (result && [result[@"found"] boolValue]) {
    CGFloat scale = [UIScreen mainScreen].scale;
    NSMutableDictionary *scaledResult = [result mutableCopy];
    scaledResult[@"x"] = @([result[@"x"] doubleValue] / scale);
    scaledResult[@"y"] = @([result[@"y"] doubleValue] / scale);
    scaledResult[@"width"] = @([result[@"width"] doubleValue] / scale);
    scaledResult[@"height"] = @([result[@"height"] doubleValue] / scale);
    return FBResponseWithObject(@{@"value" : scaledResult});
  } else if (result) {
    return FBResponseWithObject(@{@"value" : result});
  } else {
    return FBResponseWithStatus([FBCommandStatus
        unknownErrorWithMessage:@"Find image failed"
                      traceback:nil]);
  }
}

#pragma mark - Touch Actions

+ (id<FBResponsePayload>)handleTapByCoord:(FBRouteRequest *)request {
  NSNumber *x = request.arguments[@"x"];
  NSNumber *y = request.arguments[@"y"];

  if (!x || !y) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"x and y are required"
                              traceback:nil]);
  }

  CGPoint targetPoint = CGPointMake(x.doubleValue, y.doubleValue);
  XCPointerEventPath *path =
      [[XCPointerEventPath alloc] initForTouchAtPoint:targetPoint offset:0];
  [path liftUpAtOffset:0.05];

  XCSynthesizedEventRecord *record =
      [[XCSynthesizedEventRecord alloc] initWithName:@"tapByCoord"];
  [record addPointerEventPath:path];

  // Fix screen lock deadlock by dispatching XCTest IPC out of the main block
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
    NSError *error;
    if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:&error]) {
      NSLog(@"[ECWDA] tapByCoord failed: %@", error.description);
    }
  });

  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleLongPress:(FBRouteRequest *)request {
  NSNumber *x = request.arguments[@"x"];
  NSNumber *y = request.arguments[@"y"];
  NSNumber *duration = request.arguments[@"duration"] ?: @(1.0);

  if (!x || !y) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"x and y are required"
                              traceback:nil]);
  }

  CGPoint targetPoint = CGPointMake(x.doubleValue, y.doubleValue);
  XCPointerEventPath *path =
      [[XCPointerEventPath alloc] initForTouchAtPoint:targetPoint offset:0];
  [path liftUpAtOffset:duration.doubleValue];

  XCSynthesizedEventRecord *record =
      [[XCSynthesizedEventRecord alloc] initWithName:@"longPressByCoord"];
  [record addPointerEventPath:path];

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
    NSError *error;
    if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:&error]) {
      NSLog(@"[ECWDA] longPress failed: %@", error.description);
    }
  });

  return FBResponseWithOK();
}

// 坐标滑动，使用 XCPointerEventPath 直接构造事件闭环
+ (id<FBResponsePayload>)handleSwipeByCoord:(FBRouteRequest *)request {
  NSNumber *fromX = request.arguments[@"fromX"];
  NSNumber *fromY = request.arguments[@"fromY"];
  NSNumber *toX = request.arguments[@"toX"];
  NSNumber *toY = request.arguments[@"toY"];
  NSNumber *duration = request.arguments[@"duration"] ?: @(0.5);

  if (!fromX || !fromY || !toX || !toY) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"fromX, fromY, toX, toY are required"
                              traceback:nil]);
  }

  CGPoint startPoint = CGPointMake(fromX.doubleValue, fromY.doubleValue);
  CGPoint endPoint = CGPointMake(toX.doubleValue, toY.doubleValue);

  XCPointerEventPath *path =
      [[XCPointerEventPath alloc] initForTouchAtPoint:startPoint offset:0];
  [path moveToPoint:endPoint atOffset:duration.doubleValue];
  [path liftUpAtOffset:duration.doubleValue + 0.05];

  XCSynthesizedEventRecord *record =
      [[XCSynthesizedEventRecord alloc] initWithName:@"swipeByCoord"];
  [record addPointerEventPath:path];

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
    NSError *error;
    if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:&error]) {
      NSLog(@"[ECWDA] swipeByCoord failed: %@", error.description);
    }
  });

  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleDoubleTap:(FBRouteRequest *)request {
  NSNumber *x = request.arguments[@"x"];
  NSNumber *y = request.arguments[@"y"];

  if (!x || !y) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"x and y are required"
                              traceback:nil]);
  }

  CGPoint targetPoint = CGPointMake(x.doubleValue, y.doubleValue);

  XCPointerEventPath *path =
      [[XCPointerEventPath alloc] initForTouchAtPoint:targetPoint offset:0];
  [path liftUpAtOffset:0.05];
  [path pressDownAtOffset:0.1];
  [path liftUpAtOffset:0.15];

  XCSynthesizedEventRecord *record =
      [[XCSynthesizedEventRecord alloc] initWithName:@"doubleTapByCoord"];
  [record addPointerEventPath:path];

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
    NSError *error;
    if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:&error]) {
      NSLog(@"[ECWDA] doubleTap failed: %@", error.description);
    }
  });

  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleClickText:(FBRouteRequest *)request {
  NSString *text = request.arguments[@"text"];

  if (!text) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"text is required"
                              traceback:nil]);
  }

  XCUIApplication *app = XCUIApplication.fb_activeApplication;
  NSPredicate *predicate =
      [NSPredicate predicateWithFormat:@"label CONTAINS[cd] %@", text];
  NSArray *elements = [app fb_descendantsMatchingPredicate:predicate
                               shouldReturnAfterFirstMatch:YES];

  if (elements.count == 0) {
    return FBResponseWithObject(
        @{@"success" : @NO, @"message" : @"Element not found"});
  }

  XCUIElement *element = elements.firstObject;
  [element tap];

  return FBResponseWithObject(@{@"success" : @YES});
}

#pragma mark - Utility Functions

+ (id<FBResponsePayload>)handleRandom:(FBRouteRequest *)request {
  NSNumber *min = request.arguments[@"min"] ?: @0;
  NSNumber *max = request.arguments[@"max"] ?: @100;

  NSInteger minVal = min.integerValue;
  NSInteger maxVal = max.integerValue;
  NSInteger random =
      minVal + arc4random_uniform((uint32_t)(maxVal - minVal + 1));

  return FBResponseWithObject(@{@"value" : @(random)});
}

+ (id<FBResponsePayload>)handleMD5:(FBRouteRequest *)request {
  NSString *text = request.arguments[@"text"];
  if (!text) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"text is required"
                              traceback:nil]);
  }

  const char *cStr = [text UTF8String];
  unsigned char digest[CC_MD5_DIGEST_LENGTH];
  CC_MD5(cStr, (CC_LONG)strlen(cStr), digest);

  NSMutableString *output =
      [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
  for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
    [output appendFormat:@"%02x", digest[i]];
  }

  return FBResponseWithObject(@{@"md5" : output});
}

#pragma mark - Script Execution

+ (id<FBResponsePayload>)handleScriptExecute:(FBRouteRequest *)request {
  NSArray *commands = request.arguments[@"commands"];

  if (!commands || ![commands isKindOfClass:[NSArray class]]) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"commands array is required"
                              traceback:nil]);
  }

  NSLog(@"[脚本动作] ====== ECWDA 收到脚本执行请求 ======");
  NSLog(@"[脚本动作] 命令数量: %lu", (unsigned long)commands.count);
  for (NSUInteger i = 0; i < commands.count; i++) {
    NSDictionary *cmd = commands[i];
    NSLog(@"[脚本动作] 命令[%lu]: action=%@, params=%@",
          (unsigned long)i, cmd[@"action"], cmd[@"params"] ?: @"{}");
  }

  XCUIApplication *app = XCUIApplication.fb_activeApplication;
  NSMutableArray *results = [NSMutableArray array];
  NSInteger successCount = 0;
  NSInteger failCount = 0;

  for (NSDictionary *command in commands) {
    NSString *action = command[@"action"];
    NSDictionary *params = command[@"params"] ?: @{};

    @try {
      if ([action isEqualToString:@"tap"]) {
        CGFloat x = [params[@"x"] doubleValue];
        CGFloat y = [params[@"y"] doubleValue];

        CGPoint targetPoint = CGPointMake(x, y);
        XCPointerEventPath *path =
            [[XCPointerEventPath alloc] initForTouchAtPoint:targetPoint
                                                     offset:0];
        [path liftUpAtOffset:0.05];
        XCSynthesizedEventRecord *record =
            [[XCSynthesizedEventRecord alloc] initWithName:@"scriptTap"];
        [record addPointerEventPath:path];
        [FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:nil];

        successCount++;
      } else if ([action isEqualToString:@"longPress"]) {
        CGFloat x = [params[@"x"] doubleValue];
        CGFloat y = [params[@"y"] doubleValue];
        CGFloat duration =
            params[@"duration"] ? [params[@"duration"] doubleValue] : 1.0;

        CGPoint targetPoint = CGPointMake(x, y);
        XCPointerEventPath *path =
            [[XCPointerEventPath alloc] initForTouchAtPoint:targetPoint
                                                     offset:0];
        [path liftUpAtOffset:duration];
        XCSynthesizedEventRecord *record =
            [[XCSynthesizedEventRecord alloc] initWithName:@"scriptLongPress"];
        [record addPointerEventPath:path];
        [FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:nil];

        successCount++;
      } else if ([action isEqualToString:@"doubleTap"]) {
        CGFloat x = [params[@"x"] doubleValue];
        CGFloat y = [params[@"y"] doubleValue];

        CGPoint targetPoint = CGPointMake(x, y);
        XCPointerEventPath *path =
            [[XCPointerEventPath alloc] initForTouchAtPoint:targetPoint
                                                     offset:0];
        [path liftUpAtOffset:0.05];
        [path pressDownAtOffset:0.1];
        [path liftUpAtOffset:0.15];
        XCSynthesizedEventRecord *record =
            [[XCSynthesizedEventRecord alloc] initWithName:@"scriptDoubleTap"];
        [record addPointerEventPath:path];
        [FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:nil];

        successCount++;
      } else if ([action isEqualToString:@"swipe"]) {
        CGFloat fromX = [params[@"fromX"] doubleValue];
        CGFloat fromY = [params[@"fromY"] doubleValue];
        CGFloat toX = [params[@"toX"] doubleValue];
        CGFloat toY = [params[@"toY"] doubleValue];
        CGFloat duration =
            params[@"duration"] ? [params[@"duration"] doubleValue] : 0.3;

        CGPoint startPoint = CGPointMake(fromX, fromY);
        CGPoint endPoint = CGPointMake(toX, toY);
        XCPointerEventPath *path =
            [[XCPointerEventPath alloc] initForTouchAtPoint:startPoint
                                                     offset:0];
        [path moveToPoint:endPoint atOffset:duration];
        [path liftUpAtOffset:duration + 0.05];

        XCSynthesizedEventRecord *record =
            [[XCSynthesizedEventRecord alloc] initWithName:@"scriptSwipe"];
        [record addPointerEventPath:path];
        [FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:nil];

        successCount++;
      } else if ([action isEqualToString:@"sleep"]) {
        CGFloat seconds =
            params[@"seconds"] ? [params[@"seconds"] doubleValue] : 1.0;
        [NSThread sleepForTimeInterval:seconds];
        successCount++;
      } else if ([action isEqualToString:@"home"]) {
        [[XCUIDevice sharedDevice] pressButton:XCUIDeviceButtonHome];
        successCount++;
      } else if ([action isEqualToString:@"swipe_up"]) {
        CGRect frame = [[UIScreen mainScreen] bounds];
        CGFloat centerX = CGRectGetMidX(frame);
        CGFloat startY = frame.size.height * 0.8;
        CGFloat endY = frame.size.height * 0.2;

        XCPointerEventPath *path = [[XCPointerEventPath alloc]
            initForTouchAtPoint:CGPointMake(centerX, startY)
                         offset:0];
        [path moveToPoint:CGPointMake(centerX, endY) atOffset:0.3];
        [path liftUpAtOffset:0.35];
        XCSynthesizedEventRecord *record =
            [[XCSynthesizedEventRecord alloc] initWithName:@"scriptSwipeUp"];
        [record addPointerEventPath:path];
        [FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:nil];

        successCount++;
      } else if ([action isEqualToString:@"swipe_down"]) {
        CGRect frame = [[UIScreen mainScreen] bounds];
        CGFloat centerX = CGRectGetMidX(frame);
        CGFloat startY = frame.size.height * 0.2;
        CGFloat endY = frame.size.height * 0.8;

        XCPointerEventPath *path = [[XCPointerEventPath alloc]
            initForTouchAtPoint:CGPointMake(centerX, startY)
                         offset:0];
        [path moveToPoint:CGPointMake(centerX, endY) atOffset:0.3];
        [path liftUpAtOffset:0.35];
        XCSynthesizedEventRecord *record =
            [[XCSynthesizedEventRecord alloc] initWithName:@"scriptSwipeDown"];
        [record addPointerEventPath:path];
        [FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:nil];

        successCount++;
      } else if ([action isEqualToString:@"swipe_left"]) {
        CGRect frame = [[UIScreen mainScreen] bounds];
        CGFloat centerY = CGRectGetMidY(frame);
        CGFloat startX = frame.size.width * 0.8;
        CGFloat endX = frame.size.width * 0.2;

        XCPointerEventPath *path = [[XCPointerEventPath alloc]
            initForTouchAtPoint:CGPointMake(startX, centerY)
                         offset:0];
        [path moveToPoint:CGPointMake(endX, centerY) atOffset:0.3];
        [path liftUpAtOffset:0.35];
        XCSynthesizedEventRecord *record =
            [[XCSynthesizedEventRecord alloc] initWithName:@"scriptSwipeLeft"];
        [record addPointerEventPath:path];
        [FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:nil];

        successCount++;
      } else if ([action isEqualToString:@"swipe_right"]) {
        CGRect frame = [[UIScreen mainScreen] bounds];
        CGFloat centerY = CGRectGetMidY(frame);
        CGFloat startX = frame.size.width * 0.2;
        CGFloat endX = frame.size.width * 0.8;

        XCPointerEventPath *path = [[XCPointerEventPath alloc]
            initForTouchAtPoint:CGPointMake(startX, centerY)
                         offset:0];
        [path moveToPoint:CGPointMake(endX, centerY) atOffset:0.3];
        [path liftUpAtOffset:0.35];
        XCSynthesizedEventRecord *record =
            [[XCSynthesizedEventRecord alloc] initWithName:@"scriptSwipeRight"];
        [record addPointerEventPath:path];
        [FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:nil];

        successCount++;
      } else if ([action isEqualToString:@"trajectory"]) {
        // 长轨迹滑动
        NSArray *points = params[@"points"];
        if (points && points.count >= 2) {
          for (NSInteger i = 0; i < points.count - 1; i++) {
            NSArray *fromPoint = points[i];
            NSArray *toPoint = points[i + 1];
            CGFloat fromX = [fromPoint[0] doubleValue];
            CGFloat fromY = [fromPoint[1] doubleValue];
            CGFloat toX = [toPoint[0] doubleValue];
            CGFloat toY = [toPoint[1] doubleValue];

            CGPoint startPoint = CGPointMake(fromX, fromY);
            CGPoint endPoint = CGPointMake(toX, toY);
            XCPointerEventPath *path =
                [[XCPointerEventPath alloc] initForTouchAtPoint:startPoint
                                                         offset:0];
            [path moveToPoint:endPoint atOffset:0.02];
            [path liftUpAtOffset:0.03];
            XCSynthesizedEventRecord *record = [[XCSynthesizedEventRecord alloc]
                initWithName:@"scriptTrajectory"];
            [record addPointerEventPath:path];
            [FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:nil];

            [NSThread sleepForTimeInterval:0.02];
          }
          successCount++;
        }
      } else {
        [results addObject:@{@"action" : action, @"status" : @"unknown"}];
        failCount++;
      }
    } @catch (NSException *exception) {
      [results addObject:@{
        @"action" : action,
        @"status" : @"error",
        @"message" : exception.reason ?: @"unknown error"
      }];
      failCount++;
    }
  }

  NSLog(@"[脚本动作] ====== ECWDA 脚本执行完成 ======");
  NSLog(@"[脚本动作] 统计: 总计 %lu 条, 成功 %ld, 失败 %ld",
        (unsigned long)commands.count, (long)successCount, (long)failCount);

  return FBResponseWithObject(@{
    @"success" : @(failCount == 0),
    @"total" : @(commands.count),
    @"successCount" : @(successCount),
    @"failCount" : @(failCount),
    @"errors" : results
  });
}

#pragma mark - QR Code

+ (id<FBResponsePayload>)handleQRCodeScan:(FBRouteRequest *)request {
  NSError *error;
  NSData *screenshotData =
      [FBScreenshot takeInOriginalResolutionWithQuality:2 error:&error];
  if (!screenshotData) {
    return FBResponseWithUnknownError(error);
  }

  UIImage *screenshot = [UIImage imageWithData:screenshotData];
  CIImage *ciImage = [[CIImage alloc] initWithImage:screenshot];

  CIDetector *detector = [CIDetector
      detectorOfType:CIDetectorTypeQRCode
             context:nil
             options:@{CIDetectorAccuracy : CIDetectorAccuracyHigh}];

  NSArray *features = [detector featuresInImage:ciImage];
  NSMutableArray *results = [NSMutableArray array];

  for (CIQRCodeFeature *feature in features) {
    if (feature.messageString) {
      CGRect bounds = feature.bounds;
      [results addObject:@{
        @"text" : feature.messageString,
        @"x" : @(bounds.origin.x),
        @"y" : @(screenshot.size.height - bounds.origin.y - bounds.size.height),
        @"width" : @(bounds.size.width),
        @"height" : @(bounds.size.height)
      }];
    }
  }

  return FBResponseWithObject(
      @{@"found" : @(results.count > 0), @"results" : results});
}

#pragma mark - Clipboard

+ (id<FBResponsePayload>)handleClipboardGet:(FBRouteRequest *)request {
  UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
  NSString *content = pasteboard.string ?: @"";
  return FBResponseWithObject(@{@"content" : content});
}

+ (id<FBResponsePayload>)handleClipboardSet:(FBRouteRequest *)request {
  NSString *text = request.arguments[@"text"];
  if (!text) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"text is required"
                              traceback:nil]);
  }

  UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
  pasteboard.string = text;
  return FBResponseWithObject(@{@"success" : @YES});
}

#pragma mark - Input Text

+ (id<FBResponsePayload>)handleInputText:(FBRouteRequest *)request {
  NSString *text = request.arguments[@"text"];
  if (!text) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"text is required"
                              traceback:nil]);
  }

  // 使用 FBTypeText 直注文字，完全绕开 Keyboard 元素查找
  // 避免 AX 树全量遍历 + Quiescence 等待导致的 26 秒卡死
  NSUInteger frequency = [FBConfiguration maxTypingFrequency];
  NSError *error = nil;
  if (!FBTypeText(text, frequency, &error)) {
    return FBResponseWithObject(@{
      @"success" : @NO,
      @"message" : error.description ?: @"FBTypeText failed"
    });
  }
  return FBResponseWithObject(@{@"success" : @YES});
}

#pragma mark - Open URL

+ (id<FBResponsePayload>)handleOpenUrl:(FBRouteRequest *)request {
  NSString *urlString = request.arguments[@"url"];
  if (!urlString) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"url is required"
                              traceback:nil]);
  }

  NSURL *url = [NSURL URLWithString:urlString];
  if (!url) {
    return FBResponseWithObject(
        @{@"success" : @NO, @"message" : @"Invalid URL"});
  }

  XCUIApplication *app = [[XCUIApplication alloc]
      initWithBundleIdentifier:@"com.apple.mobilesafari"];
  [app activate];

  // 使用 Siri 快捷方式或者等待 Safari 打开后输入 URL
  // 这里我们使用系统 API 尝试打开
  dispatch_async(dispatch_get_main_queue(), ^{
    [[UIApplication sharedApplication] openURL:url
                                       options:@{}
                             completionHandler:nil];
  });

  return FBResponseWithObject(@{@"success" : @YES, @"url" : urlString});
}

#pragma mark - Node Operations

+ (id<FBResponsePayload>)handleNodeFindByText:(FBRouteRequest *)request {
  NSString *text = request.arguments[@"text"];
  NSNumber *partial = request.arguments[@"partial"] ?: @YES;

  if (!text) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"text is required"
                              traceback:nil]);
  }

  XCUIApplication *app = XCUIApplication.fb_activeApplication;
  NSPredicate *predicate;

  if ([partial boolValue]) {
    predicate = [NSPredicate
        predicateWithFormat:@"label CONTAINS[cd] %@ OR value CONTAINS[cd] %@",
                            text, text];
  } else {
    predicate = [NSPredicate
        predicateWithFormat:@"label == %@ OR value == %@", text, text];
  }

  NSArray *elements = [app fb_descendantsMatchingPredicate:predicate
                               shouldReturnAfterFirstMatch:NO];
  NSMutableArray *results = [NSMutableArray array];

  for (XCUIElement *element in elements) {
    CGRect frame = element.frame;
    [results addObject:@{
      @"type" : element.elementType == XCUIElementTypeButton ? @"Button"
      : element.elementType == XCUIElementTypeStaticText     ? @"StaticText"
      : element.elementType == XCUIElementTypeTextField      ? @"TextField"
                                                             : @"Other",
      @"label" : element.label ?: @"",
      @"value" : element.value ?: [NSNull null],
      @"x" : @(frame.origin.x),
      @"y" : @(frame.origin.y),
      @"width" : @(frame.size.width),
      @"height" : @(frame.size.height),
      @"enabled" : @(element.isEnabled),
      @"identifier" : element.identifier ?: @""
    }];
  }

  return FBResponseWithObject(
      @{@"count" : @(results.count), @"elements" : results});
}

+ (id<FBResponsePayload>)handleNodeFindByType:(FBRouteRequest *)request {
  NSString *typeStr = request.arguments[@"type"];

  if (!typeStr) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"type is required"
                              traceback:nil]);
  }

  XCUIApplication *app = XCUIApplication.fb_activeApplication;
  XCUIElementType elementType = XCUIElementTypeAny;

  if ([typeStr isEqualToString:@"Button"]) {
    elementType = XCUIElementTypeButton;
  } else if ([typeStr isEqualToString:@"StaticText"]) {
    elementType = XCUIElementTypeStaticText;
  } else if ([typeStr isEqualToString:@"TextField"]) {
    elementType = XCUIElementTypeTextField;
  } else if ([typeStr isEqualToString:@"Image"]) {
    elementType = XCUIElementTypeImage;
  } else if ([typeStr isEqualToString:@"Cell"]) {
    elementType = XCUIElementTypeCell;
  } else if ([typeStr isEqualToString:@"Switch"]) {
    elementType = XCUIElementTypeSwitch;
  }

  XCUIElementQuery *query = [app descendantsMatchingType:elementType];
  NSMutableArray *results = [NSMutableArray array];

  for (NSInteger i = 0; i < query.count && i < 100; i++) {
    XCUIElement *element = [query elementBoundByIndex:i];
    if (element.exists) {
      CGRect frame = element.frame;
      [results addObject:@{
        @"index" : @(i),
        @"label" : element.label ?: @"",
        @"value" : element.value ?: [NSNull null],
        @"x" : @(frame.origin.x),
        @"y" : @(frame.origin.y),
        @"width" : @(frame.size.width),
        @"height" : @(frame.size.height),
        @"enabled" : @(element.isEnabled)
      }];
    }
  }

  return FBResponseWithObject(
      @{@"count" : @(results.count), @"elements" : results});
}

+ (id<FBResponsePayload>)handleNodeGetAll:(FBRouteRequest *)request {
  XCUIApplication *app = XCUIApplication.fb_activeApplication;
  NSMutableArray *results = [NSMutableArray array];

  // 获取常见可交互元素类型
  NSArray *types = @[
    @(XCUIElementTypeButton), @(XCUIElementTypeStaticText),
    @(XCUIElementTypeTextField), @(XCUIElementTypeSecureTextField),
    @(XCUIElementTypeSwitch), @(XCUIElementTypeImage), @(XCUIElementTypeLink)
  ];

  for (NSNumber *typeNum in types) {
    XCUIElementType type = [typeNum integerValue];
    XCUIElementQuery *query = [app descendantsMatchingType:type];

    for (NSInteger i = 0; i < query.count && i < 50; i++) {
      XCUIElement *element = [query elementBoundByIndex:i];
      if (element.exists && (element.isEnabled || element.label.length > 0)) {
        CGRect frame = element.frame;
        NSString *typeStr = @"Unknown";
        if (type == XCUIElementTypeButton)
          typeStr = @"Button";
        else if (type == XCUIElementTypeStaticText)
          typeStr = @"StaticText";
        else if (type == XCUIElementTypeTextField)
          typeStr = @"TextField";
        else if (type == XCUIElementTypeSecureTextField)
          typeStr = @"SecureTextField";
        else if (type == XCUIElementTypeSwitch)
          typeStr = @"Switch";
        else if (type == XCUIElementTypeImage)
          typeStr = @"Image";
        else if (type == XCUIElementTypeLink)
          typeStr = @"Link";

        [results addObject:@{
          @"type" : typeStr,
          @"label" : element.label ?: @"",
          @"value" : element.value ?: [NSNull null],
          @"x" : @(frame.origin.x),
          @"y" : @(frame.origin.y),
          @"width" : @(frame.size.width),
          @"height" : @(frame.size.height),
          @"enabled" : @(element.isEnabled),
          @"identifier" : element.identifier ?: @""
        }];
      }
    }
  }

  return FBResponseWithObject(
      @{@"count" : @(results.count), @"elements" : results});
}

+ (id<FBResponsePayload>)handleNodeClick:(FBRouteRequest *)request {
  NSString *text = request.arguments[@"text"];
  NSString *identifier = request.arguments[@"identifier"];

  if (!text && !identifier) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"text or identifier is required"
                              traceback:nil]);
  }

  XCUIApplication *app = XCUIApplication.fb_activeApplication;
  XCUIElement *element = nil;

  if (identifier && identifier.length > 0) {
    element = app.buttons[identifier];
    if (!element.exists) {
      element = app.staticTexts[identifier];
    }
    if (!element.exists) {
      element = [[app descendantsMatchingType:XCUIElementTypeAny]
                    matchingIdentifier:identifier]
                    .firstMatch;
    }
  } else if (text) {
    NSPredicate *predicate =
        [NSPredicate predicateWithFormat:@"label CONTAINS[cd] %@", text];
    NSArray *elements = [app fb_descendantsMatchingPredicate:predicate
                                 shouldReturnAfterFirstMatch:YES];
    if (elements.count > 0) {
      element = elements.firstObject;
    }
  }

  if (element && element.exists) {
    [element tap];
    return FBResponseWithObject(@{@"success" : @YES});
  } else {
    return FBResponseWithObject(
        @{@"success" : @NO, @"message" : @"Element not found"});
  }
}

#pragma mark - Base64

+ (id<FBResponsePayload>)handleBase64Encode:(FBRouteRequest *)request {
  NSString *text = request.arguments[@"text"];
  if (!text) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"text is required"
                              traceback:nil]);
  }

  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
  NSString *encoded = [data base64EncodedStringWithOptions:0];
  return FBResponseWithObject(@{@"encoded" : encoded});
}

+ (id<FBResponsePayload>)handleBase64Decode:(FBRouteRequest *)request {
  NSString *encoded = request.arguments[@"encoded"];
  if (!encoded) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"encoded is required"
                              traceback:nil]);
  }

  NSData *data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
  if (!data) {
    return FBResponseWithObject(
        @{@"success" : @NO, @"message" : @"Invalid base64 string"});
  }

  NSString *decoded = [[NSString alloc] initWithData:data
                                            encoding:NSUTF8StringEncoding];
  return FBResponseWithObject(@{@"decoded" : decoded ?: @""});
}

#pragma mark - Vibrate

+ (id<FBResponsePayload>)handleVibrate:(FBRouteRequest *)request {
  AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
  return FBResponseWithObject(@{@"success" : @YES});
}

#pragma mark - Save to Album

+ (id<FBResponsePayload>)handleSaveToAlbum:(FBRouteRequest *)request {
  NSError *error;
  NSData *screenshotData =
      [FBScreenshot takeInOriginalResolutionWithQuality:2 error:&error];
  if (!screenshotData) {
    return FBResponseWithUnknownError(error);
  }

  UIImage *screenshot = [UIImage imageWithData:screenshotData];

  __block BOOL success = NO;
  __block NSString *errorMsg = nil;

  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

  [[PHPhotoLibrary sharedPhotoLibrary]
      performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromImage:screenshot];
      }
      completionHandler:^(BOOL succeeded, NSError *err) {
        success = succeeded;
        if (err) {
          errorMsg = err.localizedDescription;
        }
        dispatch_semaphore_signal(semaphore);
      }];

  dispatch_semaphore_wait(semaphore,
                          dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

  if (success) {
    return FBResponseWithObject(
        @{@"success" : @YES, @"message" : @"Screenshot saved to album"});
  } else {
    return FBResponseWithObject(@{
      @"success" : @NO,
      @"message" : errorMsg ?: @"Failed to save to album"
    });
  }
}

#pragma mark - App Info

+ (id<FBResponsePayload>)handleAppInfo:(FBRouteRequest *)request {
  XCUIApplication *app = XCUIApplication.fb_activeApplication;

  return FBResponseWithObject(@{
    @"bundleId" : [app valueForKey:@"bundleID"] ?: @"",
    @"state" : @(app.state),
    @"stateDescription" : app.state == XCUIApplicationStateRunningForeground
        ? @"foreground"
    : app.state == XCUIApplicationStateRunningBackground ? @"background"
    : app.state == XCUIApplicationStateNotRunning        ? @"notRunning"
                                                         : @"unknown",
    @"frame" : @{
      @"x" : @(app.frame.origin.x),
      @"y" : @(app.frame.origin.y),
      @"width" : @(app.frame.size.width),
      @"height" : @(app.frame.size.height)
    }
  });
}

#pragma mark - Touch Monitoring

+ (id<FBResponsePayload>)handleTouchStart:(FBRouteRequest *)request {
  FBTouchMonitor *monitor = [FBTouchMonitor sharedMonitor];
  BOOL success = [monitor startMonitoring];

  return FBResponseWithObject(@{
    @"success" : @(success),
    @"message" : success
        ? @"Touch monitoring started"
        : @"Failed to start touch monitoring (APIs may not be available)"
  });
}

+ (id<FBResponsePayload>)handleTouchStop:(FBRouteRequest *)request {
  FBTouchMonitor *monitor = [FBTouchMonitor sharedMonitor];
  [monitor stopMonitoring];

  return FBResponseWithObject(
      @{@"success" : @(YES), @"message" : @"Touch monitoring stopped"});
}

+ (id<FBResponsePayload>)handleTouchEvents:(FBRouteRequest *)request {
  FBTouchMonitor *monitor = [FBTouchMonitor sharedMonitor];

  // Check if we should clear events after reading
  BOOL peek = [request.arguments[@"peek"] boolValue];
  NSArray *events =
      peek ? [monitor peekRecentEvents] : [monitor getRecentEvents];

  return FBResponseWithObject(
      @{@"monitoring" : @(monitor.isMonitoring), @"events" : events});
}

#pragma mark - Helper Methods

+ (NSInteger)parseColor:(NSString *)colorStr {
  NSString *hex = colorStr;
  if ([hex hasPrefix:@"#"]) {
    hex = [hex substringFromIndex:1];
  }
  if ([hex hasPrefix:@"0x"] || [hex hasPrefix:@"0X"]) {
    hex = [hex substringFromIndex:2];
  }

  unsigned int colorValue = 0;
  [[NSScanner scannerWithString:hex] scanHexInt:&colorValue];
  return colorValue;
}

@end
