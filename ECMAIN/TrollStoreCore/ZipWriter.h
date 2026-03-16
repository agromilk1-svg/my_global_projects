// ZipWriter.h - ZIP file creator using zlib
#import <Foundation/Foundation.h>

@interface ZipWriter : NSObject

/**
 * Create a ZIP file from a directory
 * @param sourcePath Path to the directory to compress
 * @param destPath Path where the ZIP file will be created
 * @param error Error pointer
 * @return YES if successful, NO otherwise
 */
+ (BOOL)createZipAtPath:(NSString *)destPath
      fromDirectoryPath:(NSString *)sourcePath
                  error:(NSError **)error;

/**
 * Create an IPA file from an app bundle
 * @param appPath Path to the .app bundle
 * @param ipaPath Path where the .ipa file will be created
 * @param error Error pointer
 * @return YES if successful, NO otherwise
 */
+ (BOOL)createIPAAtPath:(NSString *)ipaPath
          fromAppBundle:(NSString *)appPath
                  error:(NSError **)error;

@end
