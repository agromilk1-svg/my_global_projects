/**
 * FBScreenshotFallback - IOSurface-based screenshot for standalone mode
 * Uses private APIs to capture screen without XCTest daemon
 */

#import "FBScreenshotFallback.h"
#import "FBErrorBuilder.h"
#import "FBLogger.h"
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach.h>

// Function pointer type for UIGetScreenImage
typedef CGImageRef (*UIGetScreenImageFunc)(void);

@implementation FBScreenshotFallback

+ (BOOL)isAvailable {
  // Check if UIGetScreenImage is accessible via dlsym
  UIGetScreenImageFunc getScreenImage = [self getScreenImageFunction];
  return getScreenImage != NULL;
}

+ (UIGetScreenImageFunc)getScreenImageFunction {
  static UIGetScreenImageFunc cachedFunc = NULL;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    // Try loading from UIKit directly
    void *handle =
        dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW);
    if (handle) {
      cachedFunc = (UIGetScreenImageFunc)dlsym(handle, "UIGetScreenImage");
      // Don't close handle to keep symbol valid
    }
  });
  return cachedFunc;
}

+ (nullable NSData *)takeScreenshotWithCompressionQuality:
                         (CGFloat)compressionQuality
                                                    error:(NSError **)error {
  @try {
    // Method 0: HTTP Request to ECMAIN
    // 【修改说明】已禁用：频繁调用(如 MJPEG 降级时) localhost HTTP
    // 会挤占系统连接池导致 usbmuxd/USB 物理层断线。 [FBLogger
    // log:@"[FBScreenshotFallback] Method 0 (HTTP to 8089) is disabled to
    // prevent USB disconnects"];

    // Method 1: IOMobileFramebuffer (Deep Fallback)
    /* ... typedefs ... */
    // Try explicit IOMobileFramebuffer framework first (standard location for
    // private symbols)
    void *iomfbHandle =
        dlopen("/System/Library/PrivateFrameworks/"
               "IOMobileFramebuffer.framework/IOMobileFramebuffer",
               RTLD_NOW);
    if (!iomfbHandle) {
      // Fallback to IOKit just in case
      iomfbHandle =
          dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    }

    if (!iomfbHandle) {
      [FBLogger
          log:@"[IOMFB] Error: Failed to dlopen IOMobileFramebuffer or IOKit"];
    } else {
      // Definitions for IOMFB
      typedef void *IOMobileFramebufferRef;
      typedef kern_return_t (*IOMobileFramebufferGetMainDisplayFunc)(
          IOMobileFramebufferRef *connection);
      typedef kern_return_t (*IOMobileFramebufferGetLayerDefaultSurfaceFunc)(
          IOMobileFramebufferRef connection, int surface, void **surfaceRef);

      // IOSurface definitions
      typedef void *IOSurfaceRef;
      typedef void (*IOSurfaceLockFunc)(IOSurfaceRef buffer, uint32_t options,
                                        uint32_t *seed);
      typedef void (*IOSurfaceUnlockFunc)(IOSurfaceRef buffer, uint32_t options,
                                          uint32_t *seed);
      typedef size_t (*IOSurfaceGetWidthFunc)(IOSurfaceRef buffer);
      typedef size_t (*IOSurfaceGetHeightFunc)(IOSurfaceRef buffer);
      typedef size_t (*IOSurfaceGetBytesPerRowFunc)(IOSurfaceRef buffer);
      typedef void *(*IOSurfaceGetBaseAddressFunc)(IOSurfaceRef buffer);

      IOMobileFramebufferGetMainDisplayFunc getMainDisplay =
          (IOMobileFramebufferGetMainDisplayFunc)dlsym(
              iomfbHandle, "IOMobileFramebufferGetMainDisplay");
      IOMobileFramebufferGetLayerDefaultSurfaceFunc getLayerSurface =
          (IOMobileFramebufferGetLayerDefaultSurfaceFunc)dlsym(
              iomfbHandle, "IOMobileFramebufferGetLayerDefaultSurface");

      if (!getMainDisplay || !getLayerSurface) {
        [FBLogger log:@"[IOMFB] Error: Missing IOMFB symbols (dlsym failed)"];
      }

      // IOSurface needs dynamic load usually, or link CoreGraphics/IOSurface
      void *iosHandle = dlopen(
          "/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
      if (!iosHandle) {
        [FBLogger log:@"[IOMFB] Error: Failed to dlopen IOSurface"];
      }

      if (getMainDisplay && getLayerSurface && iosHandle) {
        /* ... IOSurface resolution ... */
        IOSurfaceLockFunc lockSurface =
            (IOSurfaceLockFunc)dlsym(iosHandle, "IOSurfaceLock");
        IOSurfaceUnlockFunc unlockSurface =
            (IOSurfaceUnlockFunc)dlsym(iosHandle, "IOSurfaceUnlock");
        IOSurfaceGetWidthFunc getWidth =
            (IOSurfaceGetWidthFunc)dlsym(iosHandle, "IOSurfaceGetWidth");
        IOSurfaceGetHeightFunc getHeight =
            (IOSurfaceGetHeightFunc)dlsym(iosHandle, "IOSurfaceGetHeight");
        IOSurfaceGetBytesPerRowFunc getBytesPerRow =
            (IOSurfaceGetBytesPerRowFunc)dlsym(iosHandle,
                                               "IOSurfaceGetBytesPerRow");
        IOSurfaceGetBaseAddressFunc getBaseAddress =
            (IOSurfaceGetBaseAddressFunc)dlsym(iosHandle,
                                               "IOSurfaceGetBaseAddress");

        IOMobileFramebufferRef connection = NULL;
        kern_return_t kr = getMainDisplay(&connection);
        if (kr != 0 || !connection) {
          [FBLogger
              logFmt:@"[IOMFB] Error: GetMainDisplay failed (kr=%d, conn=%p)",
                     kr, connection];
        } else {
          void *surface = NULL;
          kr = getLayerSurface(connection, 0, &surface);
          if (kr != 0 || !surface) {
            [FBLogger logFmt:@"[IOMFB] Error: GetLayerDefaultSurface(0) failed "
                             @"(kr=%d, surf=%p)",
                             kr, surface];
            // Try surface 1
            kr = getLayerSurface(connection, 1, &surface);
            if (kr != 0 || !surface) {
              [FBLogger logFmt:@"[IOMFB] Error: GetLayerDefaultSurface(1) "
                               @"failed (kr=%d, surf=%p)",
                               kr, surface];
            }
          }

          if (surface) {
            if (lockSurface && unlockSurface && getBaseAddress) {
              lockSurface(surface, 0x00000001, NULL); // kIOSurfaceLockReadOnly

              size_t width = getWidth(surface);
              size_t height = getHeight(surface);
              size_t bytesPerRow = getBytesPerRow(surface);
              void *baseAddr = getBaseAddress(surface);

              [FBLogger
                  logFmt:@"[IOMFB] Surface Locked: %zdx%zd, bpr=%zd, addr=%p",
                         width, height, bytesPerRow, baseAddr];

              if (baseAddr) {
                CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                CGContextRef context = CGBitmapContextCreate(
                    baseAddr, width, height, 8, bytesPerRow, colorSpace,
                    kCGBitmapByteOrder32Little |
                        kCGImageAlphaPremultipliedFirst);

                if (context) {
                  CGImageRef newImage = CGBitmapContextCreateImage(context);
                  if (newImage) {
                    NSData *result =
                        [self jpegDataFromCGImage:newImage
                               compressionQuality:compressionQuality];
                    CGImageRelease(newImage);
                    CGContextRelease(context);
                    CGColorSpaceRelease(colorSpace);
                    unlockSurface(surface, 0x00000001, NULL);

                    if (result) {
                      [FBLogger
                          log:@"Screenshot captured via IOMobileFramebuffer"];
                      return result;
                    } else {
                      [FBLogger log:@"[IOMFB] Error: JPEG conversion failed"];
                    }
                  } else {
                    [FBLogger log:@"[IOMFB] Error: CGBitmapContextCreateImage "
                                  @"failed"];
                    CGContextRelease(context);
                  }
                } else {
                  [FBLogger log:@"[IOMFB] Error: CGBitmapContextCreate failed"];
                }
                CGColorSpaceRelease(colorSpace);
              } else {
                [FBLogger log:@"[IOMFB] Error: Base address is NULL"];
              }
              unlockSurface(surface, 0x00000001, NULL);
            }
          }
        }
      }
    }

    // Method 2: Try _UICreateScreenUIImage (works on iOS 9-18 with TrollStore)
    // This is the most reliable method (normally) if entitlements are strictly
    // enforced
    typedef UIImage *(*UICreateScreenUIImageFunc)(void);
    static UICreateScreenUIImageFunc createScreenUIImage = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      void *handle = dlopen(NULL, RTLD_NOW);
      if (handle) {
        createScreenUIImage =
            (UICreateScreenUIImageFunc)dlsym(handle, "_UICreateScreenUIImage");
      }
    });

    if (createScreenUIImage) {
      UIImage *screenImage = createScreenUIImage();
      if (screenImage) {
        NSData *jpegData =
            UIImageJPEGRepresentation(screenImage, compressionQuality);
        if (jpegData) {
          [FBLogger
              log:@"Screenshot captured via _UICreateScreenUIImage (Fallback)"];
          return jpegData;
        } else {
          [FBLogger
              log:@"[_UICreateScreenUIImage] Error: JPEG conversion failed"];
        }
      } else {
        [FBLogger log:@"[_UICreateScreenUIImage] Error: returned nil "
                      @"(permission denied?)"];
      }
    } else {
      [FBLogger log:@"[_UICreateScreenUIImage] Symbol not found"];
    }

    // Method 3: Try UIGetScreenImage via dlsym
    UIGetScreenImageFunc getScreenImage = [self getScreenImageFunction];
    if (getScreenImage) {
      CGImageRef screenImage = getScreenImage();
      if (screenImage != NULL) {
        NSData *jpegData = [self jpegDataFromCGImage:screenImage
                                  compressionQuality:compressionQuality];
        if (jpegData &&
            jpegData.length > 1024) { // Basic check for potentially valid image
          [FBLogger log:@"Screenshot captured via UIGetScreenImage (Fallback)"];
          return jpegData;
        } else {
          [FBLogger log:@"[UIGetScreenImage] Error: Invalid data or JPEG conv "
                        @"failed"];
        }
      } else {
        [FBLogger log:@"[UIGetScreenImage] Error: returned NULL"];
      }
    } else {
      [FBLogger log:@"[UIGetScreenImage] Symbol not found"];
    }

    // Method 4: Fallback to UIWindow snapshot (only captures app content)
    __block UIWindow *keyWindow = nil;

    if ([NSThread isMainThread]) {
      keyWindow = [self findKeyWindow];
    } else {
      dispatch_sync(dispatch_get_main_queue(), ^{
        keyWindow = [self findKeyWindow];
      });
    }

    if (keyWindow) {
      __block NSData *jpegData = nil;

      void (^captureBlock)(void) = ^{
        UIGraphicsBeginImageContextWithOptions(keyWindow.bounds.size, NO, 0);
        [keyWindow drawViewHierarchyInRect:keyWindow.bounds
                        afterScreenUpdates:NO];
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        if (image) {
          jpegData = UIImageJPEGRepresentation(image, compressionQuality);
        }
      };

      if ([NSThread isMainThread]) {
        captureBlock();
      } else {
        dispatch_sync(dispatch_get_main_queue(), captureBlock);
      }

      if (jpegData) {
        [FBLogger log:@"Screenshot captured via UIWindow snapshot (app content "
                      @"only)"];
        return jpegData;
      }
    }

    // All methods failed
    if (error) {
      *error = [[FBErrorBuilder builder]
                   withDescription:
                       @"Failed to capture screenshot: no available method"]
                   .build;
    }
    return nil;

  } @catch (NSException *exception) {
    [FBLogger logFmt:@"Screenshot exception: %@", exception.reason];
    if (error) {
      *error =
          [[FBErrorBuilder builder]
              withDescription:[NSString
                                  stringWithFormat:@"Screenshot exception: %@",
                                                   exception.reason]]
              .build;
    }
    return nil;
  }
}

+ (UIWindow *)findKeyWindow {
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if ([scene isKindOfClass:[UIWindowScene class]]) {
      UIWindowScene *windowScene = (UIWindowScene *)scene;
      for (UIWindow *window in windowScene.windows) {
        if (window.isKeyWindow) {
          return window;
        }
      }
    }
  }
  return nil;
}

+ (NSData *)jpegDataFromCGImage:(CGImageRef)cgImage
             compressionQuality:(CGFloat)quality {
  if (cgImage == NULL) {
    return nil;
  }

  UIImage *uiImage = [UIImage imageWithCGImage:cgImage];
  return UIImageJPEGRepresentation(uiImage, quality);
}

@end
