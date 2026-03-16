//
//  TSIPAInfo.h
//  IPAInfo
//
//  Created by Lars Fröder on 22.10.22.
//

#import "ZipReader.h"
#import <Foundation/Foundation.h>
@import UIKit;

@interface TSAppInfo : NSObject {
  NSString *_path;
  BOOL _isArchive;
  struct archive *_archive;

  NSString *_cachedAppBundleName;
  NSString *_cachedRegistrationState;
  NSDictionary *_cachedInfoDictionary;
  NSDictionary *_cachedInfoDictionariesByPluginSubpaths;
  NSDictionary *_cachedEntitlementsByBinarySubpaths;
  UIImage *_cachedPreviewIcon;
  int64_t _cachedSize;
  NSURL *_cachedDataContainerURL;
}

- (instancetype)initWithIPAPath:(NSString *)ipaPath;
- (instancetype)initWithAppBundlePath:(NSString *)bundlePath;
- (NSError *)determineAppBundleName;
- (NSError *)loadInfoDictionary;
- (NSError *)loadEntitlements;
- (NSError *)loadPreviewIcon;

- (NSError *)sync_loadBasicInfo;
- (NSError *)sync_loadInfo;

- (void)loadBasicInfoWithCompletion:(void (^)(NSError *))completionHandler;
- (void)loadInfoWithCompletion:(void (^)(NSError *))completionHandler;

- (NSString *)displayName;
- (NSString *)bundleIdentifier;
- (NSString *)versionString;
- (NSString *)sizeString;
- (NSString *)bundlePath;
- (NSString *)executablePath;
- (NSString *)registrationState;
- (NSURL *)dataContainerURL;

- (UIImage *)iconForSize:(CGSize)size;

- (NSAttributedString *)detailedInfoTitle;
- (NSAttributedString *)detailedInfoDescription;
//- (UIImage*)image;
- (NSDictionary *)entitlements;
- (BOOL)isDebuggable;
- (void)log;

@end
