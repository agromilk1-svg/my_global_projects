#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// TrollStore Shim to provide missing symbols

// 1. trollStoreUserDefaults
NSUserDefaults *trollStoreUserDefaults(void) {
  return [NSUserDefaults standardUserDefaults];
}

// 2. imageWithSize
UIImage *imageWithSize(UIImage *image, CGSize size) {
  if (!image)
    return nil;
  UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
  [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
  UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return newImage;
}

// 3. LICreateIconForImage
// Stub implementation returning the input image
CGImageRef LICreateIconForImage(CGImageRef image, int variant,
                                int precomposed) {
  if (image) {
    CGImageRetain(image);
    return image;
  }
  return NULL;
}
