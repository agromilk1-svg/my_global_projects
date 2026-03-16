// ZipWriter.m - ZIP file creator using zlib
#import "ZipWriter.h"
#import <sys/stat.h>
#import <zlib.h>

// ZIP format structures
#pragma pack(push, 1)
typedef struct {
  uint32_t signature; // 0x04034b50
  uint16_t versionNeeded;
  uint16_t flags;
  uint16_t compression;
  uint16_t modTime;
  uint16_t modDate;
  uint32_t crc32;
  uint32_t compressedSize;
  uint32_t uncompressedSize;
  uint16_t fileNameLength;
  uint16_t extraFieldLength;
} ZipLocalFileHeader;

typedef struct {
  uint32_t signature; // 0x02014b50
  uint16_t versionMadeBy;
  uint16_t versionNeeded;
  uint16_t flags;
  uint16_t compression;
  uint16_t modTime;
  uint16_t modDate;
  uint32_t crc32;
  uint32_t compressedSize;
  uint32_t uncompressedSize;
  uint16_t fileNameLength;
  uint16_t extraFieldLength;
  uint16_t commentLength;
  uint16_t diskNumberStart;
  uint16_t internalAttributes;
  uint32_t externalAttributes;
  uint32_t localHeaderOffset;
} ZipCentralDirHeader;

typedef struct {
  uint32_t signature; // 0x06054b50
  uint16_t diskNumber;
  uint16_t centralDirDisk;
  uint16_t numEntriesThisDisk;
  uint16_t numEntriesTotal;
  uint32_t centralDirSize;
  uint32_t centralDirOffset;
  uint16_t commentLength;
} ZipEndOfCentralDir;
#pragma pack(pop)

#define ZIP_LOCAL_FILE_SIG 0x04034b50
#define ZIP_CENTRAL_DIR_SIG 0x02014b50
#define ZIP_END_CENTRAL_SIG 0x06054b50

@implementation ZipWriter

+ (BOOL)createZipAtPath:(NSString *)destPath
      fromDirectoryPath:(NSString *)sourcePath
                  error:(NSError **)error {

  NSFileManager *fm = [NSFileManager defaultManager];

  // Get all files recursively
  NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:sourcePath];
  NSMutableArray *relativePaths = [NSMutableArray array];
  NSString *item;
  while ((item = [enumerator nextObject])) {
    [relativePaths addObject:item];
  }

  // Open output file
  FILE *zipFile = fopen([destPath fileSystemRepresentation], "wb");
  if (!zipFile) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"ZipWriter"
                     code:1
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Failed to create output file"
                 }];
    }
    return NO;
  }

  // Track central directory entries
  NSMutableData *centralDir = [NSMutableData data];
  uint32_t numEntries = 0;

  for (NSString *relativePath in relativePaths) {
    NSString *fullPath =
        [sourcePath stringByAppendingPathComponent:relativePath];
    BOOL isDirectory = NO;
    [fm fileExistsAtPath:fullPath isDirectory:&isDirectory];

    // Skip directories (they're implicit in paths)
    if (isDirectory)
      continue;

    // Read file data
    NSData *fileData = [NSData dataWithContentsOfFile:fullPath];
    if (!fileData)
      continue;

    // Calculate CRC32
    uLong crc = crc32(0L, Z_NULL, 0);
    crc = crc32(crc, [fileData bytes], (uInt)[fileData length]);

    // Compress data
    uLongf compressedLen = compressBound((uLong)[fileData length]);
    Bytef *compressedData = malloc(compressedLen);

    int compressResult =
        compress2(compressedData, &compressedLen, [fileData bytes],
                  (uLong)[fileData length], Z_DEFAULT_COMPRESSION);

    // Use raw deflate for ZIP (skip zlib header)
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    strm.next_in = (Bytef *)[fileData bytes];
    strm.avail_in = (uInt)[fileData length];

    uLongf deflatedLen = compressBound((uLong)[fileData length]);
    Bytef *deflatedData = malloc(deflatedLen);
    strm.next_out = deflatedData;
    strm.avail_out = (uInt)deflatedLen;

    // Use -MAX_WBITS for raw deflate (no zlib header)
    if (deflateInit2(&strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8,
                     Z_DEFAULT_STRATEGY) != Z_OK) {
      free(compressedData);
      free(deflatedData);
      continue;
    }

    deflate(&strm, Z_FINISH);
    deflateEnd(&strm);

    uLongf actualCompressedLen = strm.total_out;
    free(compressedData);

    // Determine if compression is beneficial
    BOOL useCompression = (actualCompressedLen < [fileData length]);

    // Get current position for central directory
    long localHeaderOffset = ftell(zipFile);

    // DOS date/time
    uint16_t dosTime = 0;
    uint16_t dosDate = 0x21; // 1980-01-01

    // Write local file header
    const char *fileName = [relativePath UTF8String];
    uint16_t fileNameLen = (uint16_t)strlen(fileName);

    ZipLocalFileHeader localHeader;
    memset(&localHeader, 0, sizeof(localHeader));
    localHeader.signature = ZIP_LOCAL_FILE_SIG;
    localHeader.versionNeeded = 20;
    localHeader.flags = 0;
    localHeader.compression = useCompression ? 8 : 0; // 8 = deflate, 0 = store
    localHeader.modTime = dosTime;
    localHeader.modDate = dosDate;
    localHeader.crc32 = (uint32_t)crc;
    localHeader.compressedSize = useCompression ? (uint32_t)actualCompressedLen
                                                : (uint32_t)[fileData length];
    localHeader.uncompressedSize = (uint32_t)[fileData length];
    localHeader.fileNameLength = fileNameLen;
    localHeader.extraFieldLength = 0;

    fwrite(&localHeader, sizeof(localHeader), 1, zipFile);
    fwrite(fileName, 1, fileNameLen, zipFile);

    // Write file data
    if (useCompression) {
      fwrite(deflatedData, 1, actualCompressedLen, zipFile);
    } else {
      fwrite([fileData bytes], 1, [fileData length], zipFile);
    }

    free(deflatedData);

    // Build central directory entry
    ZipCentralDirHeader cdHeader;
    memset(&cdHeader, 0, sizeof(cdHeader));
    cdHeader.signature = ZIP_CENTRAL_DIR_SIG;
    cdHeader.versionMadeBy = 0x031E; // Unix, version 3.0
    cdHeader.versionNeeded = 20;
    cdHeader.flags = 0;
    cdHeader.compression = useCompression ? 8 : 0;
    cdHeader.modTime = dosTime;
    cdHeader.modDate = dosDate;
    cdHeader.crc32 = (uint32_t)crc;
    cdHeader.compressedSize = localHeader.compressedSize;
    cdHeader.uncompressedSize = (uint32_t)[fileData length];
    cdHeader.fileNameLength = fileNameLen;
    cdHeader.extraFieldLength = 0;
    cdHeader.commentLength = 0;
    cdHeader.diskNumberStart = 0;
    cdHeader.internalAttributes = 0;
    cdHeader.externalAttributes = 0x81A40000; // Regular file, 644 permissions
    cdHeader.localHeaderOffset = (uint32_t)localHeaderOffset;

    [centralDir appendBytes:&cdHeader length:sizeof(cdHeader)];
    [centralDir appendBytes:fileName length:fileNameLen];

    numEntries++;
  }

  // Write central directory
  long centralDirOffset = ftell(zipFile);
  fwrite([centralDir bytes], 1, [centralDir length], zipFile);

  // Write end of central directory
  ZipEndOfCentralDir endRecord;
  memset(&endRecord, 0, sizeof(endRecord));
  endRecord.signature = ZIP_END_CENTRAL_SIG;
  endRecord.diskNumber = 0;
  endRecord.centralDirDisk = 0;
  endRecord.numEntriesThisDisk = numEntries;
  endRecord.numEntriesTotal = numEntries;
  endRecord.centralDirSize = (uint32_t)[centralDir length];
  endRecord.centralDirOffset = (uint32_t)centralDirOffset;
  endRecord.commentLength = 0;

  fwrite(&endRecord, sizeof(endRecord), 1, zipFile);

  fclose(zipFile);

  return YES;
}

+ (BOOL)createIPAAtPath:(NSString *)ipaPath
          fromAppBundle:(NSString *)appPath
                  error:(NSError **)error {

  NSFileManager *fm = [NSFileManager defaultManager];

  // Create temp directory with Payload structure
  NSString *tmpDir = [NSTemporaryDirectory()
      stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
  NSString *payloadDir = [tmpDir stringByAppendingPathComponent:@"Payload"];

  NSError *createError;
  if (![fm createDirectoryAtPath:payloadDir
          withIntermediateDirectories:YES
                           attributes:nil
                                error:&createError]) {
    if (error)
      *error = createError;
    return NO;
  }

  // Copy app bundle to Payload
  NSString *appName = [appPath lastPathComponent];
  NSString *destAppPath = [payloadDir stringByAppendingPathComponent:appName];

  NSError *copyError;
  if (![fm copyItemAtPath:appPath toPath:destAppPath error:&copyError]) {
    if (error)
      *error = copyError;
    [fm removeItemAtPath:tmpDir error:nil];
    return NO;
  }

  // Create ZIP (IPA is just a ZIP file)
  BOOL success = [self createZipAtPath:ipaPath
                     fromDirectoryPath:tmpDir
                                 error:error];

  // Cleanup
  [fm removeItemAtPath:tmpDir error:nil];

  return success;
}

@end
