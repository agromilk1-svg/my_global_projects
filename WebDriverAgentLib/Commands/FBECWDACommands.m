/**
 * ECWDA Extended Commands
 * 扩展功能命令 - 包含找色、OCR、长按、双击等功能
 */

#import "FBECWDACommands.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CommonCrypto/CommonDigest.h>
#import <Photos/Photos.h>
#import <Vision/Vision.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <XCTest/XCTest.h>
#import "XCUIScreen.h"

#import "FBConfiguration.h"
#import "FBOCREngine.h"
#import "FBResponsePayload.h"
#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBRunLoopSpinner.h"
#import "FBScreenshot.h"
#import "FBScreenshotFallback.h"
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
#import "FBActiveAppDetectionPoint.h"
#import "FBXCAXClientProxy.h"
#import "FBXCAccessibilityElement.h"
#import "FBXCElementSnapshot.h"
#import "FBXCElementSnapshotWrapper.h"
#import "FBElementTypeTransformer.h"
#import "XCUIElement+FBWebDriverAttributes.h"
#import "XCTestManager_ManagerInterface-Protocol.h"

// ECMAIN 在线状态标志
static BOOL _isEcmainOnline = YES;

// 上次尝试拉活的时间（避免频繁拉起）
static NSTimeInterval _lastEcmainLaunchTime = 0;

// 模板图解码缓存（MD5 → UIImage），避免同一模板反复 Base64 解码
static NSCache *_templateImageCache = nil;

@implementation FBECWDACommands

#pragma mark - 保活探测 (ECWDA → ECMAIN via 8089)

+ (void)load {
  // 初始化模板图缓存
  _templateImageCache = [[NSCache alloc] init];
  _templateImageCache.countLimit = 50; // 最多缓存 50 张模板

  // [v1821] ECMAIN 保活已迁移至 XCUIDevice+FBHealthCheck.m
  NSLog(@"[ECWDA] FBECWDACommands loaded (Template Cache initialized)");
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

    // 找图（含截图，可能因 IPC 卡死）
    [[FBRoute POST:@"/wda/findImage"].withoutSession
        respondWithTarget:self
                   action:@selector(handleFindImage:)],

    // 纯匹配（不截图，由调用方提供截图数据，防止 IPC 卡死）
    [[FBRoute POST:@"/wda/matchImage"].withoutSession
        respondWithTarget:self
                   action:@selector(handleMatchImage:)],

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
    [[FBRoute POST:@"/wda/elementAtPoint"].withoutSession
        respondWithTarget:self
                   action:@selector(handleGetElementAtPoint:)],
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

#pragma mark - Element At Point

+ (id<FBResponsePayload>)handleGetElementAtPoint:(FBRouteRequest *)request {
  NSNumber *xNum = request.arguments[@"x"];
  NSNumber *yNum = request.arguments[@"y"];

  if (!xNum || !yNum) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"x and y are required" traceback:nil]);
  }

  // WDA internals use logic coordinates.
  CGPoint pt = CGPointMake(xNum.doubleValue, yNum.doubleValue);
  
  __block id<FBXCAccessibilityElement> axElement = nil;
  __block NSError *proxyError = nil;
  id<XCTestManager_ManagerInterface> proxy = [FBXCTestDaemonsProxy testRunnerProxy];
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [proxy _XCT_requestElementAtPoint:pt
                              reply:^(id element, NSError *error) {
                                if (nil == error) {
                                  axElement = element;
                                } else {
                                  proxyError = error;
                                }
                                dispatch_semaphore_signal(sem);
                              }];
                              
  // Wait up to 5 seconds
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)));
  
  if (!axElement) {
    if (proxyError) {
        [FBLogger logFmt:@"Cannot request screen point at %@: %@", NSStringFromCGPoint(pt), proxyError];
    }
    return FBResponseWithObject(@{@"found": @NO, @"error": proxyError ? proxyError.localizedDescription : @"Timeout or element not found"});
  }
  
  id<FBXCElementSnapshot> snapshot = [[FBXCAXClientProxy sharedClient] snapshotForElement:axElement
                                                                           attributes:nil
                                                                              inDepth:NO
                                                                                error:nil];
  if (!snapshot) {
    return FBResponseWithObject(@{@"found": @NO});
  }
  
  FBXCElementSnapshotWrapper *wrappedSnapshot = [FBXCElementSnapshotWrapper ensureWrapped:snapshot];
  
  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  info[@"found"] = @YES;
  info[@"depth"] = @(snapshot.depth);
  info[@"type"] = [FBElementTypeTransformer shortStringWithElementType:snapshot.elementType];
  
  NSString *wdName = wrappedSnapshot.wdName;
  NSString *wdLabel = wrappedSnapshot.wdLabel;
  NSString *wdValue = wrappedSnapshot.wdValue;
  
  if (wdName && ![wdName isEqual:[NSNull null]] && [wdName isKindOfClass:[NSString class]]) info[@"name"] = wdName;
  if (wdLabel && ![wdLabel isEqual:[NSNull null]] && [wdLabel isKindOfClass:[NSString class]]) info[@"label"] = wdLabel;
  if (wdValue && ![wdValue isEqual:[NSNull null]] && [wdValue isKindOfClass:[NSString class]]) info[@"value"] = wdValue;
  
  info[@"x"] = @(snapshot.frame.origin.x);
  info[@"y"] = @(snapshot.frame.origin.y);
  info[@"width"] = @(snapshot.frame.size.width);
  info[@"height"] = @(snapshot.frame.size.height);
  
  return FBResponseWithObject(info);
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

  // [v1738-fix] 防卡死：截图超时保护（与 handleFindImage 一致）
  __block NSData *screenshotData = nil;
  __block NSError *screenshotError = nil;
  dispatch_semaphore_t screenshotSema = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *error = nil;
    screenshotData = [FBScreenshot takeInOriginalResolutionWithScreenID:[(NSNumber *)[[XCUIScreen mainScreen] valueForKey:@"displayID"] longLongValue] compressionQuality:1.0 uti:UTTypePNG timeout:10.0 error:&error];
    screenshotError = error;
    dispatch_semaphore_signal(screenshotSema);
  });
  long screenshotWait = dispatch_semaphore_wait(
      screenshotSema,
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));
  if (screenshotWait != 0) {
    NSLog(@"[ECWDA] ⚠️ findColor 截图超时(10s)");
    return FBResponseWithStatus([FBCommandStatus
        unknownErrorWithMessage:@"Screenshot timed out (10s)"
                      traceback:nil]);
  }
  if (!screenshotData) {
    return FBResponseWithUnknownError(screenshotError);
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

  // [v1738-fix] 防卡死：截图超时保护（与 handleFindImage 一致）
  __block NSData *screenshotData = nil;
  __block NSError *screenshotError = nil;
  dispatch_semaphore_t screenshotSema = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *error = nil;
    screenshotData = [FBScreenshot takeInOriginalResolutionWithScreenID:[(NSNumber *)[[XCUIScreen mainScreen] valueForKey:@"displayID"] longLongValue] compressionQuality:1.0 uti:UTTypePNG timeout:10.0 error:&error];
    screenshotError = error;
    dispatch_semaphore_signal(screenshotSema);
  });
  long screenshotWait = dispatch_semaphore_wait(
      screenshotSema,
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));
  if (screenshotWait != 0) {
    NSLog(@"[ECWDA] ⚠️ findMultiColor 截图超时(10s)");
    return FBResponseWithStatus([FBCommandStatus
        unknownErrorWithMessage:@"Screenshot timed out (10s)"
                      traceback:nil]);
  }
  if (!screenshotData) {
    return FBResponseWithUnknownError(screenshotError);
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

  CGFloat scale = [UIScreen mainScreen].scale;
  if (region) {
    startX = [region[@"x"] floatValue] * scale;
    startY = [region[@"y"] floatValue] * scale;
    endX = startX + [region[@"width"] floatValue] * scale;
    endY = startY + [region[@"height"] floatValue] * scale;
  }

  // [v1778.5] 计算多点找色的近似宽高度 bounding box
  NSInteger maxOffsetX = 0;
  NSInteger maxOffsetY = 0;
  for (NSDictionary *offsetColor in offsetColors) {
     NSInteger ox = [offsetColor[@"offsetX"] integerValue];
     NSInteger oy = [offsetColor[@"offsetY"] integerValue];
     if (abs((int)ox) > maxOffsetX) maxOffsetX = abs((int)ox);
     if (abs((int)oy) > maxOffsetY) maxOffsetY = abs((int)oy);
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
        CGFloat scale = [UIScreen mainScreen].scale;
        return FBResponseWithObject(
            @{@"x" : @(x / scale), @"y" : @(y / scale), @"width" : @(maxOffsetX / scale), @"height" : @(maxOffsetY / scale), @"found" : @YES});
      }
    }
  }

  CFRelease(pixelData);
  return FBResponseWithObject(@{@"x" : @(-1), @"y" : @(-1), @"width" : @0, @"height" : @0, @"found" : @NO});
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

  // [v1738-fix] 防卡死：截图超时保护
  __block NSData *screenshotData = nil;
  __block NSError *screenshotError = nil;
  dispatch_semaphore_t screenshotSema = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *error = nil;
    screenshotData = [FBScreenshot takeInOriginalResolutionWithScreenID:[(NSNumber *)[[XCUIScreen mainScreen] valueForKey:@"displayID"] longLongValue] compressionQuality:1.0 uti:UTTypePNG timeout:10.0 error:&error];
    screenshotError = error;
    dispatch_semaphore_signal(screenshotSema);
  });
  long screenshotWait = dispatch_semaphore_wait(
      screenshotSema,
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));
  if (screenshotWait != 0) {
    NSLog(@"[ECWDA] ⚠️ cmpColor 截图超时(10s)");
    return FBResponseWithStatus([FBCommandStatus
        unknownErrorWithMessage:@"Screenshot timed out (10s)"
                      traceback:nil]);
  }
  if (!screenshotData) {
    return FBResponseWithUnknownError(screenshotError);
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

  // [v1738-fix] 防卡死：截图超时保护
  __block NSData *screenshotData = nil;
  __block NSError *screenshotError = nil;
  dispatch_semaphore_t screenshotSema = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *error = nil;
    screenshotData = [FBScreenshot takeInOriginalResolutionWithScreenID:[(NSNumber *)[[XCUIScreen mainScreen] valueForKey:@"displayID"] longLongValue] compressionQuality:1.0 uti:UTTypePNG timeout:10.0 error:&error];
    screenshotError = error;
    dispatch_semaphore_signal(screenshotSema);
  });
  long screenshotWait = dispatch_semaphore_wait(
      screenshotSema,
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));
  if (screenshotWait != 0) {
    NSLog(@"[ECWDA] ⚠️ getPixel 截图超时(10s)");
    return FBResponseWithStatus([FBCommandStatus
        unknownErrorWithMessage:@"Screenshot timed out (10s)"
                      traceback:nil]);
  }
  if (!screenshotData) {
    return FBResponseWithUnknownError(screenshotError);
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
  // 防卡死：截图超时保护（与 handleFindImage 一致）
  __block NSData *screenshotData = nil;
  __block NSError *screenshotError = nil;
  dispatch_semaphore_t sema = dispatch_semaphore_create(0);

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *error = nil;
    screenshotData = [FBScreenshot takeInOriginalResolutionWithScreenID:[(NSNumber *)[[XCUIScreen mainScreen] valueForKey:@"displayID"] longLongValue] compressionQuality:1.0 uti:UTTypePNG timeout:10.0 error:&error];
    screenshotError = error;
    dispatch_semaphore_signal(sema);
  });

  long waitResult = dispatch_semaphore_wait(
      sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));

  if (waitResult != 0) {
    NSLog(@"[ECWDA] ⚠️ OCR 截图超时(10s)，TikTok 等高负载场景可能阻塞了 XCTest "
          @"IPC");
    return FBResponseWithStatus([FBCommandStatus
        unknownErrorWithMessage:@"Screenshot timed out (10s)"
                      traceback:nil]);
  }

  if (!screenshotData) {
    return FBResponseWithUnknownError(screenshotError);
  }
  UIImage *screenshot = [UIImage imageWithData:screenshotData];

  NSArray<FBOCRTextResult *> *results;
  NSDictionary *regionDict = request.arguments[@"region"];
  NSArray *languages = request.arguments[@"languages"];
  CGFloat scale = [UIScreen mainScreen].scale;
  if (regionDict) {
    CGRect region = CGRectMake([regionDict[@"x"] doubleValue] * scale,
                               [regionDict[@"y"] doubleValue] * scale,
                               [regionDict[@"width"] doubleValue] * scale,
                               [regionDict[@"height"] doubleValue] * scale);
    results = [[FBOCREngine sharedEngine] recognizeText:screenshot
                                               inRegion:region
                                              languages:languages];
  } else {
    results = [[FBOCREngine sharedEngine] recognizeText:screenshot
                                              languages:languages];
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

  // [v79] 性能埋点：记录截图起始时间
  CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();

  // [v79] 核心修复：优先使用 IOSurface 物理显存直读（不走 testmanagerd，不受动画卡顿影响）
  __block NSData *screenshotData = nil;
  __block NSError *screenshotError = nil;
  
  NSError *fallbackError = nil;
  screenshotData = [FBScreenshotFallback takeScreenshotWithCompressionQuality:0.9 error:&fallbackError];
  
  CFAbsoluteTime t1 = CFAbsoluteTimeGetCurrent();
  
  if (screenshotData) {
    NSLog(@"[Perf] 🚀 findText 取图 (IOSurface 物理直读) 耗时: %.2f ms, 数据量: %lu bytes",
          (t1 - t0) * 1000.0, (unsigned long)screenshotData.length);
  } else {
    // 降级回 XCTest 通道（会触发 Idleness 检测，可能卡 8 秒）
    NSLog(@"[Perf] ⚠️ IOSurface 取图失败: %@, 降级至 XCTest 通道", fallbackError);
    
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSError *error = nil;
      screenshotData = [FBScreenshot takeInOriginalResolutionWithScreenID:[(NSNumber *)[[XCUIScreen mainScreen] valueForKey:@"displayID"] longLongValue]
                                                       compressionQuality:1.0
                                                                      uti:UTTypePNG
                                                                  timeout:10.0
                                                                    error:&error];
      screenshotError = error;
      dispatch_semaphore_signal(sema);
    });

    long waitResult = dispatch_semaphore_wait(
        sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));

    t1 = CFAbsoluteTimeGetCurrent();
    NSLog(@"[Perf] ⏱️ findText 取图 (XCTest 降级) 耗时: %.2f ms", (t1 - t0) * 1000.0);
    
    if (waitResult != 0) {
      NSLog(@"[ECWDA] ⚠️ findText 截图超时(10s)，TikTok 等高负载场景可能阻塞了 "
            @"XCTest IPC");
      return FBResponseWithStatus([FBCommandStatus
          unknownErrorWithMessage:@"Screenshot timed out (10s)"
                        traceback:nil]);
    }
  }

  if (!screenshotData) {
    return FBResponseWithUnknownError(screenshotError);
  }
  UIImage *screenshot = [UIImage imageWithData:screenshotData];

  CFAbsoluteTime t2 = CFAbsoluteTimeGetCurrent();
  FBOCRTextResult *result = [[FBOCREngine sharedEngine] findText:text
                                                         inImage:screenshot];
  CFAbsoluteTime t3 = CFAbsoluteTimeGetCurrent();
  NSLog(@"[Perf] 🔍 findText OCR 推理耗时: %.2f ms (解码+识别+匹配)", (t3 - t2) * 1000.0);
  NSLog(@"[Perf] 📊 findText 总耗时: %.2f ms (取图 %.0f + OCR %.0f)",
        (t3 - t0) * 1000.0, (t1 - t0) * 1000.0, (t3 - t2) * 1000.0);

  if (result) {
    // [v1769-fix] 不再重复除以屏幕缩放比 (scale)，因为底层 FBOCREngine 中已映射转换至 Point 体系。不再引发双重缩放偏差。
    return FBResponseWithObject(
        @{@"found" : @YES, @"result" : [result toDictionary]});
  } else {
    return FBResponseWithObject(@{@"found" : @NO});
  }
}

/// 计算 Base64 字符串的 MD5（用于模板缓存 key）
+ (NSString *)md5ForString:(NSString *)input {
  const char *cStr = [input UTF8String];
  unsigned char digest[CC_MD5_DIGEST_LENGTH];
  CC_MD5(cStr, (CC_LONG)strlen(cStr), digest);
  NSMutableString *output =
      [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
  for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
    [output appendFormat:@"%02x", digest[i]];
  return output;
}

+ (id<FBResponsePayload>)handleFindImage:(FBRouteRequest *)request {
  NSString *templateBase64 = request.arguments[@"template"];
  NSNumber *threshold = request.arguments[@"threshold"] ?: @(0.8);

  if (!templateBase64) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"Missing 'template' parameter (base64)"
                              traceback:nil]);
  }

  // ====== 优化 1：模板图缓存（避免同模板重复 Base64 解码） ======
  NSString *cacheKey = [self md5ForString:templateBase64];
  UIImage *templateImage = [_templateImageCache objectForKey:cacheKey];
  if (!templateImage) {
    NSData *templateData = [[NSData alloc]
        initWithBase64EncodedString:templateBase64
                            options:
                                NSDataBase64DecodingIgnoreUnknownCharacters];
    templateImage = [UIImage imageWithData:templateData];
    if (templateImage) {
      [_templateImageCache setObject:templateImage forKey:cacheKey];
    }
  }
  if (!templateImage) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"Invalid template image data"
                              traceback:nil]);
  }

  // ====== 优化 2：截图超时保护（防止 XCTest 截图卡死锁住 HTTP 线程） ======
  __block NSData *screenshotData = nil;
  __block NSError *screenshotError = nil;
  dispatch_semaphore_t screenshotSema = dispatch_semaphore_create(0);

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *error = nil;
    screenshotData = [FBScreenshot takeInOriginalResolutionWithScreenID:[(NSNumber *)[[XCUIScreen mainScreen] valueForKey:@"displayID"] longLongValue] compressionQuality:1.0 uti:UTTypePNG timeout:10.0 error:&error];
    screenshotError = error;
    dispatch_semaphore_signal(screenshotSema);
  });

  // 最多等待 10 秒，超时则主动返回失败，避免线程永久卡死
  long waitResult = dispatch_semaphore_wait(
      screenshotSema,
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));

  if (waitResult != 0) {
    NSLog(@"[ECWDA] ⚠️ findImage 截图超时(10s)，可能系统截图 API 被阻塞");
    return FBResponseWithStatus([FBCommandStatus
        unknownErrorWithMessage:@"Screenshot timed out (10s)"
                      traceback:nil]);
  }

  if (!screenshotData) {
    return FBResponseWithUnknownError(screenshotError);
  }
  UIImage *screenshot = [UIImage imageWithData:screenshotData];

  // ====== 优化 3：模板匹配超时保护（防止 OpenCV 卡死阻塞整个 HTTP 服务）
  // ======
  __block NSDictionary *result = nil;
  dispatch_semaphore_t matchSema = dispatch_semaphore_create(0);

  UIImage *capturedTemplate = templateImage;
  UIImage *capturedScreenshot = screenshot;
  float capturedThreshold = threshold.floatValue;

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    result = [[FBOCREngine sharedEngine] findImage:capturedTemplate
                                           inImage:capturedScreenshot
                                         threshold:capturedThreshold];
    dispatch_semaphore_signal(matchSema);
  });

  // 最多等待 3 秒，超时则立即释放 HTTP 线程
  long matchWait = dispatch_semaphore_wait(
      matchSema,
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)));

  if (matchWait != 0) {
    NSLog(
        @"[ECWDA] ⚠️ findImage 模板匹配超时(3s)，OpenCV 可能卡死，跳过本次找图");
    return FBResponseWithObject(@{
      @"value" :
          @{@"found" : @NO, @"error" : @"Template matching timed out (3s)"}
    });
  }

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

// ====== 纯模板匹配（不截图，由调用方提供截图 base64，防止 XCTest IPC 卡死） ======
+ (id<FBResponsePayload>)handleMatchImage:(FBRouteRequest *)request {
  @autoreleasepool { // 强制释放截图 Base64 等大对象，防止内存堆积

  NSString *screenshotBase64 = request.arguments[@"screenshot"];
  NSString *templateBase64 = request.arguments[@"template"];
  NSNumber *threshold = request.arguments[@"threshold"] ?: @(0.8);

  if (!screenshotBase64 || !templateBase64) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"Missing 'screenshot' or 'template' parameter (base64)"
                              traceback:nil]);
  }

  // 解码截图（用完即释放）
  UIImage *screenshot = nil;
  {
    NSData *screenshotData = [[NSData alloc]
        initWithBase64EncodedString:screenshotBase64
                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    screenshot = [UIImage imageWithData:screenshotData];
    // screenshotData 在此作用域结束后被 ARC 立刻释放，节省 ~3-5MB
  }
  if (!screenshot) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"Invalid screenshot image data"
                              traceback:nil]);
  }

  // 解码模板（使用缓存）
  NSString *cacheKey = [self md5ForString:templateBase64];
  UIImage *templateImage = [_templateImageCache objectForKey:cacheKey];
  if (!templateImage) {
    NSData *templateData = [[NSData alloc]
        initWithBase64EncodedString:templateBase64
                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    templateImage = [UIImage imageWithData:templateData];
    if (templateImage) {
      [_templateImageCache setObject:templateImage forKey:cacheKey];
    }
  }
  if (!templateImage) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"Invalid template image data"
                              traceback:nil]);
  }

  // 纯 CPU 模板匹配（带 3 秒超时保护）
  __block NSDictionary *result = nil;
  dispatch_semaphore_t matchSema = dispatch_semaphore_create(0);

  float capturedThreshold = threshold.floatValue;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    result = [[FBOCREngine sharedEngine] findImage:templateImage
                                           inImage:screenshot
                                         threshold:capturedThreshold];
    dispatch_semaphore_signal(matchSema);
  });

  long matchWait = dispatch_semaphore_wait(
      matchSema,
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)));

  if (matchWait != 0) {
    NSLog(@"[ECWDA] ⚠️ matchImage 模板匹配超时(3s)");
    return FBResponseWithObject(@{@"found" : @NO, @"error" : @"Template matching timed out (3s)"});
  }

  if (result) {
    NSMutableDictionary *finalRes = [result mutableCopy];
    finalRes[@"screenshotWidth"] = @(screenshot.size.width * screenshot.scale);
    finalRes[@"screenshotHeight"] = @(screenshot.size.height * screenshot.scale);
    finalRes[@"templateWidth"] = @(templateImage.size.width * templateImage.scale);
    finalRes[@"templateHeight"] = @(templateImage.size.height * templateImage.scale);

    if ([result[@"found"] boolValue]) {
      CGFloat scale = [UIScreen mainScreen].scale;
      finalRes[@"x"] = @([result[@"x"] doubleValue] / scale);
      finalRes[@"y"] = @([result[@"y"] doubleValue] / scale);
      finalRes[@"width"] = @([result[@"width"] doubleValue] / scale);
      finalRes[@"height"] = @([result[@"height"] doubleValue] / scale);
    }
    return FBResponseWithObject(finalRes);
  } else {
    return FBResponseWithStatus([FBCommandStatus
        unknownErrorWithMessage:@"Match image failed"
                      traceback:nil]);
  }

  } // @autoreleasepool
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

  // 防卡死重构：废弃 Accessibility Tree 遍历，改用 OCR 截图路径
  // 优先使用 IOSurface 物理显存直读，完全免疫视频动画带来的 XCTest IPC 死锁阻塞
  __block NSData *screenshotData = nil;
  __block NSError *screenshotError = nil;
  
  NSError *fallbackError = nil;
  screenshotData = [FBScreenshotFallback takeScreenshotWithCompressionQuality:0.9 error:&fallbackError];

  if (!screenshotData) {
    NSLog(@"[ECWDA] ⚠️ clickText IOSurface 取图失败: %@, 降级至 XCTest 慢速通道", fallbackError);
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSError *error = nil;
      screenshotData = [FBScreenshot takeInOriginalResolutionWithScreenID:[(NSNumber *)[[XCUIScreen mainScreen] valueForKey:@"displayID"] longLongValue] compressionQuality:1.0 uti:UTTypePNG timeout:10.0 error:&error];
      screenshotError = error;
      dispatch_semaphore_signal(sema);
    });

    long waitResult = dispatch_semaphore_wait(
        sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));

    if (waitResult != 0) {
      NSLog(@"[ECWDA] ⚠️ clickText 降级截图超时(10s)");
      return FBResponseWithObject(
          @{@"success" : @NO, @"message" : @"Screenshot timed out (10s)"});
    }
  }

  if (!screenshotData) {
    return FBResponseWithObject(
        @{@"success" : @NO, @"message" : @"Screenshot failed"});
  }
  UIImage *screenshot = [UIImage imageWithData:screenshotData];

  FBOCRTextResult *result = [[FBOCREngine sharedEngine] findText:text
                                                         inImage:screenshot];
  if (!result) {
    return FBResponseWithObject(
        @{@"success" : @NO, @"message" : @"Text not found via OCR"});
  }

  // 计算文字中心坐标并点击 (坐标已在底层处理为 Point，切勿双重除以 Scale)
  CGFloat centerX = result.frame.origin.x + result.frame.size.width / 2.0;
  CGFloat centerY = result.frame.origin.y + result.frame.size.height / 2.0;

  CGPoint targetPoint = CGPointMake(centerX, centerY);
  XCPointerEventPath *path =
      [[XCPointerEventPath alloc] initForTouchAtPoint:targetPoint offset:0];
  [path liftUpAtOffset:0.05];

  XCSynthesizedEventRecord *record =
      [[XCSynthesizedEventRecord alloc] initWithName:@"clickTextOCR"];
  [record addPointerEventPath:path];

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
    NSError *error;
    if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:&error]) {
      NSLog(@"[ECWDA] clickText tap failed: %@", error.description);
    }
  });

  return FBResponseWithObject(
      @{@"success" : @YES, @"x" : @(centerX), @"y" : @(centerY)});
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
    NSLog(@"[脚本动作] 命令[%lu]: action=%@, params=%@", (unsigned long)i,
          cmd[@"action"], cmd[@"params"] ?: @"{}");
  }

  // [v1738-fix] 删除未使用的 fb_activeApplication 调用
  // 所有 tap/swipe 已改用 XCPointerEventPath 直接坐标操作，不需要 App 引用
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
      [FBScreenshot takeInOriginalResolutionWithScreenID:[(NSNumber *)[[XCUIScreen mainScreen] valueForKey:@"displayID"] longLongValue] compressionQuality:1.0 uti:UTTypePNG timeout:10.0 error:&error];
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

  // [v1738-fix] 超时保护：将 Accessibility 树遍历放入后台线程，最多等待 10 秒
  __block NSMutableArray *foundResults = [NSMutableArray array];
  dispatch_semaphore_t sema = dispatch_semaphore_create(0);

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @try {
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
      for (XCUIElement *element in elements) {
        CGRect frame = element.frame;
        [foundResults addObject:@{
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
    } @catch (NSException *e) {
      NSLog(@"[ECWDA] ⚠️ handleNodeFindByText 异常: %@", e.reason);
    }
    dispatch_semaphore_signal(sema);
  });

  long waitResult = dispatch_semaphore_wait(
      sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));
  if (waitResult != 0) {
    NSLog(@"[ECWDA] ⚠️ handleNodeFindByText 超时(10s)");
    return FBResponseWithObject(@{
      @"count" : @0,
      @"elements" : @[],
      @"error" : @"Accessibility tree query timed out (10s)"
    });
  }

  return FBResponseWithObject(
      @{@"count" : @(foundResults.count), @"elements" : foundResults});
}

+ (id<FBResponsePayload>)handleNodeFindByType:(FBRouteRequest *)request {
  NSString *typeStr = request.arguments[@"type"];

  if (!typeStr) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"type is required"
                              traceback:nil]);
  }

  // [v1738-fix] 超时保护：将 Accessibility 树遍历放入后台线程，最多等待 10 秒
  __block NSMutableArray *foundResults = [NSMutableArray array];
  dispatch_semaphore_t sema = dispatch_semaphore_create(0);

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @try {
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
      for (NSInteger i = 0; i < query.count && i < 100; i++) {
        XCUIElement *element = [query elementBoundByIndex:i];
        if (element.exists) {
          CGRect frame = element.frame;
          [foundResults addObject:@{
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
    } @catch (NSException *e) {
      NSLog(@"[ECWDA] ⚠️ handleNodeFindByType 异常: %@", e.reason);
    }
    dispatch_semaphore_signal(sema);
  });

  long waitResult = dispatch_semaphore_wait(
      sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));
  if (waitResult != 0) {
    NSLog(@"[ECWDA] ⚠️ handleNodeFindByType 超时(10s)");
    return FBResponseWithObject(@{
      @"count" : @0,
      @"elements" : @[],
      @"error" : @"Accessibility tree query timed out (10s)"
    });
  }

  return FBResponseWithObject(
      @{@"count" : @(foundResults.count), @"elements" : foundResults});
}

+ (id<FBResponsePayload>)handleNodeGetAll:(FBRouteRequest *)request {
  // [v1738-fix] 超时保护：将 7 种类型遍历放入后台线程，最多等待 10 秒
  __block NSMutableArray *foundResults = [NSMutableArray array];
  dispatch_semaphore_t sema = dispatch_semaphore_create(0);

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @try {
      XCUIApplication *app = XCUIApplication.fb_activeApplication;

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
            if (type == XCUIElementTypeButton) typeStr = @"Button";
            else if (type == XCUIElementTypeStaticText) typeStr = @"StaticText";
            else if (type == XCUIElementTypeTextField) typeStr = @"TextField";
            else if (type == XCUIElementTypeSecureTextField) typeStr = @"SecureTextField";
            else if (type == XCUIElementTypeSwitch) typeStr = @"Switch";
            else if (type == XCUIElementTypeImage) typeStr = @"Image";
            else if (type == XCUIElementTypeLink) typeStr = @"Link";

            [foundResults addObject:@{
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
    } @catch (NSException *e) {
      NSLog(@"[ECWDA] ⚠️ handleNodeGetAll 异常: %@", e.reason);
    }
    dispatch_semaphore_signal(sema);
  });

  long waitResult = dispatch_semaphore_wait(
      sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));
  if (waitResult != 0) {
    NSLog(@"[ECWDA] ⚠️ handleNodeGetAll 超时(10s)");
    return FBResponseWithObject(@{
      @"count" : @0,
      @"elements" : @[],
      @"error" : @"Accessibility tree query timed out (10s)"
    });
  }

  return FBResponseWithObject(
      @{@"count" : @(foundResults.count), @"elements" : foundResults});
}

+ (id<FBResponsePayload>)handleNodeClick:(FBRouteRequest *)request {
  NSString *text = request.arguments[@"text"];
  NSString *identifier = request.arguments[@"identifier"];

  if (!text && !identifier) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"text or identifier is required"
                              traceback:nil]);
  }

  // [v1738-fix] 超时保护：将元素查找放入后台线程，最多等待 10 秒
  __block BOOL clicked = NO;
  dispatch_semaphore_t sema = dispatch_semaphore_create(0);

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @try {
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
        clicked = YES;
      }
    } @catch (NSException *e) {
      NSLog(@"[ECWDA] ⚠️ handleNodeClick 异常: %@", e.reason);
    }
    dispatch_semaphore_signal(sema);
  });

  long waitResult = dispatch_semaphore_wait(
      sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));
  if (waitResult != 0) {
    NSLog(@"[ECWDA] ⚠️ handleNodeClick 超时(10s)");
    return FBResponseWithObject(
        @{@"success" : @NO, @"message" : @"Element query timed out (10s)"});
  }

  if (clicked) {
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
      [FBScreenshot takeInOriginalResolutionWithScreenID:[(NSNumber *)[[XCUIScreen mainScreen] valueForKey:@"displayID"] longLongValue] compressionQuality:1.0 uti:UTTypePNG timeout:10.0 error:&error];
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
  // [v1738-fix] 超时保护：fb_activeApplication 可能在复杂 App 场景下耗时
  __block NSDictionary *appInfo = nil;
  dispatch_semaphore_t sema = dispatch_semaphore_create(0);

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @try {
      XCUIApplication *app = XCUIApplication.fb_activeApplication;
      appInfo = @{
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
      };
    } @catch (NSException *e) {
      NSLog(@"[ECWDA] ⚠️ handleAppInfo 异常: %@", e.reason);
    }
    dispatch_semaphore_signal(sema);
  });

  long waitResult = dispatch_semaphore_wait(
      sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));
  if (waitResult != 0) {
    NSLog(@"[ECWDA] ⚠️ handleAppInfo 超时(10s)");
    return FBResponseWithObject(@{
      @"bundleId" : @"",
      @"state" : @(-1),
      @"stateDescription" : @"timeout",
      @"error" : @"fb_activeApplication timed out (10s)"
    });
  }

  return FBResponseWithObject(appInfo ?: @{@"error" : @"Failed to get app info"});
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
