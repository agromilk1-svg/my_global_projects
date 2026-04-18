/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBAlert.h"

#import "FBConfiguration.h"
#import "FBErrorBuilder.h"
#import "FBLogger.h"
#import "FBXCElementSnapshotWrapper+Helpers.h"
#import "FBXCodeCompatibility.h"
#import "XCUIApplication+FBAlert.h"
#import "XCUIApplication.h"
#import "XCUIElement+FBClassChain.h"
#import "XCUIElement+FBTyping.h"
#import "XCUIElement+FBUtilities.h"
#import "XCUIElement+FBWebDriverAttributes.h"

@interface FBAlert ()
@property(nonatomic, strong) XCUIApplication *application;
@property(nonatomic, strong, nullable) XCUIElement *element;
@end

@implementation FBAlert

+ (instancetype)alertWithApplication:(XCUIApplication *)application {
  FBAlert *alert = [FBAlert new];
  alert.application = application;
  return alert;
}

+ (instancetype)alertWithElement:(XCUIElement *)element {
  FBAlert *alert = [FBAlert new];
  alert.element = element;
  alert.application = element.application;
  return alert;
}

- (BOOL)isPresent {
  @try {
    if (nil == self.alertElement) {
      return NO;
    }
    [self.alertElement fb_customSnapshot];
    return YES;
  } @catch (NSException *) {
    return NO;
  }
}

- (BOOL)notPresentWithError:(NSError **)error {
  return [[[FBErrorBuilder builder] withDescriptionFormat:@"No alert is open"]
      buildError:error];
}

+ (BOOL)isSafariWebAlertWithSnapshot:(id<FBXCElementSnapshot>)snapshot {
  if (snapshot.elementType != XCUIElementTypeOther) {
    return NO;
  }

  FBXCElementSnapshotWrapper *snapshotWrapper =
      [FBXCElementSnapshotWrapper ensureWrapped:snapshot];
  id<FBXCElementSnapshot> application =
      [snapshotWrapper fb_parentMatchingType:XCUIElementTypeApplication];
  return nil != application &&
         [application.label isEqualToString:FB_SAFARI_APP_NAME];
}

- (NSString *)text {
  if (!self.isPresent) {
    return nil;
  }

  NSMutableArray<NSString *> *resultText = [NSMutableArray array];
  id<FBXCElementSnapshot> snapshot =
      self.alertElement.lastSnapshot ?: [self.alertElement fb_customSnapshot];
  BOOL isSafariAlert = [self.class isSafariWebAlertWithSnapshot:snapshot];
  [snapshot
      enumerateDescendantsUsingBlock:^(id<FBXCElementSnapshot> descendant) {
        XCUIElementType elementType = descendant.elementType;
        if (!(elementType == XCUIElementTypeTextView ||
              elementType == XCUIElementTypeStaticText)) {
          return;
        }

        FBXCElementSnapshotWrapper *descendantWrapper =
            [FBXCElementSnapshotWrapper ensureWrapped:descendant];
        if (elementType == XCUIElementTypeStaticText &&
            nil != [descendantWrapper
                       fb_parentMatchingType:XCUIElementTypeButton]) {
          return;
        }

        NSString *text = descendantWrapper.wdLabel ?: descendantWrapper.wdValue;
        if (isSafariAlert && nil != descendant.parent) {
          FBXCElementSnapshotWrapper *descendantParentWrapper =
              [FBXCElementSnapshotWrapper ensureWrapped:descendant.parent];
          NSString *parentText = descendantParentWrapper.wdLabel
                                     ?: descendantParentWrapper.wdValue;
          if ([parentText isEqualToString:text]) {
            // Avoid duplicated texts on Safari alerts
            return;
          }
        }

        if (nil != text) {
          [resultText addObject:[NSString stringWithFormat:@"%@", text]];
        }
      }];
  return [resultText componentsJoinedByString:@"\n"];
}

- (BOOL)typeText:(NSString *)text error:(NSError **)error {
  if (!self.isPresent) {
    return [self notPresentWithError:error];
  }

  NSPredicate *textCollectorPredicate = [NSPredicate
      predicateWithFormat:@"elementType IN {%lu,%lu}", XCUIElementTypeTextField,
                          XCUIElementTypeSecureTextField];
  NSArray<XCUIElement *> *dstFields =
      [[self.alertElement descendantsMatchingType:XCUIElementTypeAny]
          matchingPredicate:textCollectorPredicate]
          .allElementsBoundByIndex;
  if (dstFields.count > 1) {
    return [[[FBErrorBuilder builder]
        withDescriptionFormat:@"The alert contains more than one input field"]
        buildError:error];
  }
  if (0 == dstFields.count) {
    return [[[FBErrorBuilder builder]
        withDescriptionFormat:@"The alert contains no input fields"]
        buildError:error];
  }
  return [dstFields.firstObject fb_typeText:text shouldClear:YES error:error];
}

- (NSArray *)buttonLabels {
  if (!self.isPresent) {
    return nil;
  }

  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  // [v2028] 强制刷新快照，避免使用过期的缓存快照（某些系统弹窗按钮在动画完成后才挂载）
  id<FBXCElementSnapshot> alertSnapshot = [self.alertElement fb_customSnapshot];
  [alertSnapshot
      enumerateDescendantsUsingBlock:^(id<FBXCElementSnapshot> descendant) {
        if (descendant.elementType != XCUIElementTypeButton) {
          return;
        }
        NSString *label =
            [FBXCElementSnapshotWrapper ensureWrapped:descendant].wdLabel;
        if (nil != label) {
          [labels addObject:[NSString stringWithFormat:@"%@", label]];
        }
      }];
  
  // [v2028降级] 针对 iOS 15 垂直堆叠按钮布局（如三按钮权限请求）进行的增强识别
  // 核心策略：遍历所有后代，排除已知干扰项，通过坐标+宽高比提取按钮文本
  if (labels.count == 0) {
    [FBLogger log:@"[v2028] 标准按钮搜索为空，启用增强降级搜索..."];
    NSString *alertText = self.text ?: @"";
    CGRect alertFrame = alertSnapshot.frame;
    // 按钮区域位于弹窗下部（约 35% 位置以下）
    CGFloat buttonAreaTop = alertFrame.origin.y + (alertFrame.size.height * 0.30);
    
    // 第一轮：收集所有合格的候选文本
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    [alertSnapshot
        enumerateDescendantsUsingBlock:^(id<FBXCElementSnapshot> descendant) {
          FBXCElementSnapshotWrapper *wrapped = [FBXCElementSnapshotWrapper ensureWrapped:descendant];
          NSString *label = wrapped.wdLabel;
          if (label.length == 0) return;
          
          // 排除已知干扰元素：滚动条、滚动指示器等
          NSString *lowerLabel = label.lowercaseString;
          if ([lowerLabel containsString:@"scroll"] ||
              [lowerLabel containsString:@"desplazamiento"] ||
              [lowerLabel containsString:@"barra de"]) {
            return;
          }
          
          CGRect frame = descendant.frame;
          // 排除尺寸异常的元素（太小的不可能是按钮）
          if (frame.size.height < 8 || frame.size.width < 30) return;
          
          // 排除不在按钮区域内的元素
          if (frame.origin.y < buttonAreaTop) return;
          
          // 排除弹窗正文的完整重复（防止将标题/正文误判为按钮）
          if (label.length > 30 && [alertText containsString:label]) return;
          
          // 避免重复
          if (![candidates containsObject:label]) {
            [candidates addObject:label];
          }
        }];
    
    // 如果第一轮有结果，直接使用
    if (candidates.count > 0) {
      [labels addObjectsFromArray:candidates];
      [FBLogger logFmt:@"[v2028] 增强降级搜索发现 %lu 个按钮: %@",
                       (unsigned long)labels.count, labels];
    } else {
      // 第二轮：如果第一轮仍无结果，放宽条件——搜索整个弹窗中所有短文本
      [FBLogger log:@"[v2028] 第一轮无结果，启用超宽松搜索（全弹窗短文本）..."];
      [alertSnapshot
          enumerateDescendantsUsingBlock:^(id<FBXCElementSnapshot> descendant) {
            FBXCElementSnapshotWrapper *wrapped = [FBXCElementSnapshotWrapper ensureWrapped:descendant];
            NSString *label = wrapped.wdLabel;
            if (label.length == 0 || label.length > 40) return;
            
            NSString *lowerLabel = label.lowercaseString;
            // 继续排除滚动条
            if ([lowerLabel containsString:@"scroll"] ||
                [lowerLabel containsString:@"desplazamiento"] ||
                [lowerLabel containsString:@"barra"]) {
              return;
            }
            
            // 排除弹窗正文片段
            if ([alertText containsString:label] && label.length > 15) return;
            
            // 只接受叶子节点或只有1个子节点的元素
            if (descendant.children.count > 1) return;
            
            if (![labels containsObject:label]) {
              [labels addObject:label];
            }
          }];
      if (labels.count > 0) {
        [FBLogger logFmt:@"[v2028] 超宽松搜索发现 %lu 个候选按钮: %@",
                         (unsigned long)labels.count, labels];
      }
    }
    
    // [v2028调试] 如果兜底都没找到，打印所有的元素来一探究竟
    if (labels.count == 0) {
      [FBLogger logFmt:@"[v2028/Debug] 在这棵树中未发现候选按钮。弹窗根节点子元素数量: %lu", (unsigned long)alertSnapshot.children.count];
      [alertSnapshot enumerateDescendantsUsingBlock:^(id<FBXCElementSnapshot> descendant) {
          FBXCElementSnapshotWrapper *wrapped = [FBXCElementSnapshotWrapper ensureWrapped:descendant];
          NSString *l = wrapped.wdLabel;
          id v = wrapped.wdValue;
          NSString *vs = @"";
          if ([v isKindOfClass:[NSString class]]) vs = (NSString *)v;
          
          if (l.length > 0 || vs.length > 0 || descendant.elementType == XCUIElementTypeButton || descendant.elementType == XCUIElementTypeStaticText) {
              [FBLogger logFmt:@"[Debug] Type:%lu, L:'%@', V:'%@', Frame:%@, Childs:%lu",
                               (unsigned long)descendant.elementType,
                               l ?: @"",
                               vs,
                               NSStringFromCGRect(descendant.frame),
                               (unsigned long)descendant.children.count];
          }
      }];
    }
  }
  
  return labels.copy;
}

- (BOOL)acceptWithError:(NSError **)error {
  if (!self.isPresent) {
    return [self notPresentWithError:error];
  }

  id<FBXCElementSnapshot> alertSnapshot =
      self.alertElement.lastSnapshot ?: [self.alertElement fb_customSnapshot];
  XCUIElement *acceptButton = nil;
  if (FBConfiguration.acceptAlertButtonSelector.length) {
    NSString *errorReason = nil;
    @try {
      acceptButton = [[self.alertElement
          fb_descendantsMatchingClassChain:FBConfiguration
                                               .acceptAlertButtonSelector
               shouldReturnAfterFirstMatch:YES] firstObject];
    } @catch (NSException *ex) {
      errorReason = ex.reason;
    }
    if (nil == acceptButton) {
      [FBLogger logFmt:@"Cannot find any match for Accept alert button using "
                       @"the class chain selector '%@'",
                       FBConfiguration.acceptAlertButtonSelector];
      if (nil != errorReason) {
        [FBLogger logFmt:@"Original error: %@", errorReason];
      }
      [FBLogger log:@"Will fallback to the default button location algorithm"];
    }
  }
  if (nil == acceptButton) {
    NSArray<XCUIElement *> *buttons =
        [self.alertElement.fb_query
            descendantsMatchingType:XCUIElementTypeButton]
            .allElementsBoundByIndex;
    acceptButton = (alertSnapshot.elementType == XCUIElementTypeAlert ||
                    [self.class isSafariWebAlertWithSnapshot:alertSnapshot])
                       ? buttons.lastObject
                       : buttons.firstObject;
  }
  // [v2028降级] 标准按钮搜索失败时，强制刷新快照后重试
  if (nil == acceptButton) {
    [FBLogger log:@"[v2028] acceptAlert: 标准搜索无结果，强制刷新 UI 树重试..."];
    [NSThread sleepForTimeInterval:0.5];
    alertSnapshot = [self.alertElement fb_customSnapshot];
    NSArray<XCUIElement *> *buttons2 =
        [self.alertElement.fb_query
            descendantsMatchingType:XCUIElementTypeButton]
            .allElementsBoundByIndex;
    acceptButton = buttons2.lastObject;
  }
  // [v2028终极降级] 仍失败，尝试搜索所有可交互的 XCUIElementTypeOther 元素
  if (nil == acceptButton) {
    [FBLogger log:@"[v2028] acceptAlert: 刷新后仍无按钮，搜索 Other 类型元素..."];
    NSArray<XCUIElement *> *others =
        [self.alertElement.fb_query
            descendantsMatchingType:XCUIElementTypeOther]
            .allElementsBoundByIndex;
    // 通知权限弹窗通常有 2 个 Other 元素充当按钮，Accept 是最后一个
    if (others.count >= 2) {
      acceptButton = others.lastObject;
      [FBLogger logFmt:@"[v2028] 使用 Other 元素作为 Accept 按钮 (共 %lu 个)",
                       (unsigned long)others.count];
    }
  }
  if (nil == acceptButton) {
    return [[[FBErrorBuilder builder]
        withDescriptionFormat:@"Failed to find accept button for alert: %@",
                              self.alertElement] buildError:error];
  }
  [acceptButton tap];
  return YES;
}

- (BOOL)dismissWithError:(NSError **)error {
  if (!self.isPresent) {
    return [self notPresentWithError:error];
  }

  id<FBXCElementSnapshot> alertSnapshot =
      self.alertElement.lastSnapshot ?: [self.alertElement fb_customSnapshot];
  XCUIElement *dismissButton = nil;
  if (FBConfiguration.dismissAlertButtonSelector.length) {
    NSString *errorReason = nil;
    @try {
      dismissButton = [[self.alertElement
          fb_descendantsMatchingClassChain:FBConfiguration
                                               .dismissAlertButtonSelector
               shouldReturnAfterFirstMatch:YES] firstObject];
    } @catch (NSException *ex) {
      errorReason = ex.reason;
    }
    if (nil == dismissButton) {
      [FBLogger logFmt:@"Cannot find any match for Dismiss alert button using "
                       @"the class chain selector '%@'",
                       FBConfiguration.dismissAlertButtonSelector];
      if (nil != errorReason) {
        [FBLogger logFmt:@"Original error: %@", errorReason];
      }
      [FBLogger log:@"Will fallback to the default button location algorithm"];
    }
  }
  if (nil == dismissButton) {
    NSArray<XCUIElement *> *buttons =
        [self.alertElement.fb_query
            descendantsMatchingType:XCUIElementTypeButton]
            .allElementsBoundByIndex;
    dismissButton = (alertSnapshot.elementType == XCUIElementTypeAlert ||
                     [self.class isSafariWebAlertWithSnapshot:alertSnapshot])
                        ? buttons.firstObject
                        : buttons.lastObject;
  }
  // [v2028降级] 与 acceptWithError 对称：强制刷新 + Other 元素搜索
  if (nil == dismissButton) {
    [FBLogger log:@"[v2028] dismissAlert: 标准搜索无结果，强制刷新 UI 树重试..."];
    [NSThread sleepForTimeInterval:0.5];
    alertSnapshot = [self.alertElement fb_customSnapshot];
    NSArray<XCUIElement *> *buttons2 =
        [self.alertElement.fb_query
            descendantsMatchingType:XCUIElementTypeButton]
            .allElementsBoundByIndex;
    dismissButton = buttons2.firstObject;
  }
  if (nil == dismissButton) {
    [FBLogger log:@"[v2028] dismissAlert: 刷新后仍无按钮，搜索 Other 类型元素..."];
    NSArray<XCUIElement *> *others =
        [self.alertElement.fb_query
            descendantsMatchingType:XCUIElementTypeOther]
            .allElementsBoundByIndex;
    if (others.count >= 2) {
      dismissButton = others.firstObject;
      [FBLogger logFmt:@"[v2028] 使用 Other 元素作为 Dismiss 按钮 (共 %lu 个)",
                       (unsigned long)others.count];
    }
  }
  if (nil == dismissButton) {
    return [[[FBErrorBuilder builder]
        withDescriptionFormat:@"Failed to find dismiss button for alert: %@",
                              self.alertElement] buildError:error];
  }
  [dismissButton tap];
  return YES;
}

- (BOOL)clickAlertButton:(NSString *)label error:(NSError **)error {
  if (!self.isPresent) {
    return [self notPresentWithError:error];
  }

  NSPredicate *predicate =
      [NSPredicate predicateWithFormat:@"label == %@", label];
  XCUIElement *requestedButton =
      [[self.alertElement descendantsMatchingType:XCUIElementTypeButton]
          matchingPredicate:predicate]
          .allElementsBoundByIndex.firstObject;
  if (!requestedButton) {
    // [v2028降级] 如果按照标准 label 找不到按钮（说明它不是 UIButton 类型），尝试暴力坐标查找
    [FBLogger logFmt:@"[v2028] clickAlertButton: 标准查找失败，尝试对全量元素进行 '%@' 文本匹配...", label];
    XCUIElementQuery *allQuery = [self.alertElement descendantsMatchingType:XCUIElementTypeAny];
    NSPredicate *p = [NSPredicate predicateWithFormat:@"label == %@", label];
    requestedButton = [allQuery matchingPredicate:p].allElementsBoundByIndex.firstObject;
  }
  
  if (!requestedButton) {
    return [[[FBErrorBuilder builder]
        withDescriptionFormat:
            @"Failed to find button with label '%@' for alert: %@", label,
            self.alertElement] buildError:error];
  }
  [requestedButton tap];
  return YES;
}

- (XCUIElement *)alertElement {
  if (nil == self.element) {
    // 只查询 SpringBoard，系统弹窗均归其管理。
    // 避免回退查前台 App（如 TikTok）导致遍历巨量 UI 树而卡死。
    XCUIApplication *systemApp = XCUIApplication.fb_systemApplication;
    self.element = systemApp.fb_alertElement;
  }
  return self.element;
}

@end
