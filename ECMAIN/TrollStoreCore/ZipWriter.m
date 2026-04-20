// ZipWriter.m - iOS-compatible ZIP / IPA creator (STORE mode, zero extra RAM)
// 所有文件用 STORE 模式 (不压缩，直接写入)，避免在内存中缓存 770MB 的压缩数据导致 OOM。
// IPA 本质是 ZIP，unzip 安装器不需要文件被压缩，STORE 完全合法。
// 正确处理:
//   ✅ 符号链接 — readlink() + Unix externalAttr (S_IFLNK)
//   ✅ 目录项 — 空 entry + trailing slash
//   ✅ 普通文件 — 流式 STORE (每 4MB 一块读写，不积压内存)
//   ✅ Unix 文件权限
//   ✅ 零 malloc 压缩缓冲，避免 OOM/SIGABRT
#import "ZipWriter.h"
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>
#import <dirent.h>
#import <zlib.h>   // only for crc32()

// ─── ZIP 常量 ────────────────────────────────────────────────────────────────
#define ZIP_LOCAL_FILE_SIG   0x04034b50
#define ZIP_CENTRAL_DIR_SIG  0x02014b50
#define ZIP_END_CENTRAL_SIG  0x06054b50
#define ZIP_VERSION_NEEDED   20
#define ZIP_VERSION_BY       0x0317  // Unix, v2.3
#define ZIP_METHOD_STORE     0

#pragma pack(push, 1)
typedef struct {
  uint32_t sig;
  uint16_t versionNeeded;
  uint16_t flags;
  uint16_t method;
  uint16_t modTime;
  uint16_t modDate;
  uint32_t crc32Val;
  uint32_t compressedSize;
  uint32_t uncompressedSize;
  uint16_t nameLen;
  uint16_t extraLen;
} ZipLFH;

typedef struct {
  uint32_t sig;
  uint16_t versionBy;
  uint16_t versionNeeded;
  uint16_t flags;
  uint16_t method;
  uint16_t modTime;
  uint16_t modDate;
  uint32_t crc32Val;
  uint32_t compressedSize;
  uint32_t uncompressedSize;
  uint16_t nameLen;
  uint16_t extraLen;
  uint16_t commentLen;
  uint16_t diskStart;
  uint16_t internalAttr;
  uint32_t externalAttr;
  uint32_t localOffset;
} ZipCDH;

typedef struct {
  uint32_t sig;
  uint16_t diskNum;
  uint16_t cdDisk;
  uint16_t cdCount;
  uint16_t cdCountTotal;
  uint32_t cdSize;
  uint32_t cdOffset;
  uint16_t commentLen;
} ZipEOCD;
#pragma pack(pop)

// ─── 工具 ─────────────────────────────────────────────────────────────────────
static void unixToDosTime(time_t t, uint16_t *dt, uint16_t *dd) {
  struct tm *tm = localtime(&t);
  if (!tm) { *dt = 0; *dd = 0x21; return; }
  *dt = (uint16_t)(((tm->tm_hour) << 11) | ((tm->tm_min) << 5) | (tm->tm_sec / 2));
  *dd = (uint16_t)((((tm->tm_year - 80) & 0x7F) << 9) | ((tm->tm_mon + 1) << 5) | tm->tm_mday);
}

@interface ZEntryObj : NSObject
@property (nonatomic, copy) NSString *relativePath;
@property (nonatomic, assign) BOOL isDir;
@property (nonatomic, assign) BOOL isSymlink;
@end
@implementation ZEntryObj
@end

static NSMutableArray *collectZEntries(NSString *root) {
  NSMutableArray *result = [NSMutableArray array];
  NSMutableArray *queue  = [NSMutableArray arrayWithObject:@""];
  NSFileManager *fm = [NSFileManager defaultManager];

  while (queue.count) {
    NSString *rel  = queue.firstObject;
    [queue removeObjectAtIndex:0];
    NSString *full = rel.length ? [root stringByAppendingPathComponent:rel] : root;

    struct stat st;
    if (lstat(full.fileSystemRepresentation, &st) != 0) continue;

    if (S_ISLNK(st.st_mode)) {
      ZEntryObj *e = [[ZEntryObj alloc] init];
      e.relativePath = rel;
      e.isDir = NO; e.isSymlink = YES;
      [result addObject:e];
    } else if (S_ISDIR(st.st_mode)) {
      if (rel.length) {
        NSString *dirRel = [rel stringByAppendingString:@"/"];
        ZEntryObj *e = [[ZEntryObj alloc] init];
        e.relativePath = dirRel;
        e.isDir = YES;
        [result addObject:e];
      }
      NSArray *children = [[fm contentsOfDirectoryAtPath:full error:nil]
                           sortedArrayUsingSelector:@selector(compare:)];
      for (NSString *child in children) {
        NSString *childRel = rel.length
            ? [rel stringByAppendingPathComponent:child] : child;
        [queue addObject:childRel];
      }
    } else if (S_ISREG(st.st_mode)) {
      ZEntryObj *e = [[ZEntryObj alloc] init];
      e.relativePath = rel;
      [result addObject:e];
    }
  }
  return result;
}

@implementation ZipWriter

// ─────────────────────────────────────────────────────────────────────────────
// createZipAtPath:fromDirectoryPath:error:
// STORE-only，流式写入，无额外内存分配
// ─────────────────────────────────────────────────────────────────────────────
+ (BOOL)createZipAtPath:(NSString *)destPath
      fromDirectoryPath:(NSString *)sourcePath
                  error:(NSError **)error {

  // ① 入参保护：sourcePath 为 nil 会导致 stringByAppendingPathComponent: 崩溃
  if (!destPath.length || !sourcePath.length) {
    if (error) *error = [NSError errorWithDomain:@"ZipWriter" code:10 userInfo:@{
      NSLocalizedDescriptionKey: [NSString stringWithFormat:
          @"入参路径不能为空 (dest=%@, src=%@)", destPath ?: @"nil", sourcePath ?: @"nil"]}];
    return NO;
  }
  NSMutableArray *entries = collectZEntries(sourcePath);

  FILE *zf = fopen(destPath.fileSystemRepresentation, "wb");
  if (!zf) {
    if (error) *error = [NSError errorWithDomain:@"ZipWriter" code:1 userInfo:@{
      NSLocalizedDescriptionKey: [NSString stringWithFormat:@"无法创建: %@", destPath]}];
    return NO;
  }

  NSMutableData *cd = [NSMutableData data];
  uint32_t numEntries = 0;

  // 4MB 流式读缓冲，一次只在内存中保留 4MB
  static const size_t kBufSize = 4 * 1024 * 1024;
  uint8_t *buf = malloc(kBufSize);
  if (!buf) {
    fclose(zf);
    if (error) *error = [NSError errorWithDomain:@"ZipWriter" code:2 userInfo:@{
      NSLocalizedDescriptionKey: @"内存不足 (4MB 缓冲)"}];
    return NO;
  }

  for (ZEntryObj *e in entries) {
    NSString *relPath = e.relativePath;
    NSString *fullPath = [sourcePath stringByAppendingPathComponent:relPath];
    NSString *fullPathClean = e.isDir
        ? [fullPath substringToIndex:fullPath.length - 1] : fullPath;

    struct stat st;
    if (lstat(fullPathClean.fileSystemRepresentation, &st) != 0) continue;

    uint16_t dt, dd;
    unixToDosTime(st.st_mtime, &dt, &dd);

    const char *name = relPath.UTF8String;
    uint16_t nameLen = (uint16_t)strlen(name);
    uint32_t localOff = (uint32_t)ftell(zf);
    uint32_t unixMode = (uint32_t)(st.st_mode & 0xFFFF);

    if (e.isDir) {
      // 目录 entry
      ZipLFH lfh = {0};
      lfh.sig = ZIP_LOCAL_FILE_SIG; lfh.versionNeeded = ZIP_VERSION_NEEDED;
      lfh.modTime = dt; lfh.modDate = dd; lfh.nameLen = nameLen;
      fwrite(&lfh, sizeof(lfh), 1, zf);
      fwrite(name, 1, nameLen, zf);

      ZipCDH cdh = {0};
      cdh.sig = ZIP_CENTRAL_DIR_SIG; cdh.versionBy = ZIP_VERSION_BY;
      cdh.versionNeeded = ZIP_VERSION_NEEDED;
      cdh.modTime = dt; cdh.modDate = dd; cdh.nameLen = nameLen;
      cdh.externalAttr = (unixMode << 16) | 0x10;
      cdh.localOffset = localOff;
      [cd appendBytes:&cdh length:sizeof(cdh)];
      [cd appendBytes:name length:nameLen];
      numEntries++;

    } else if (e.isSymlink) {
      // Symlink entry — 内容是 readlink() 目标
      char target[PATH_MAX] = {0};
      ssize_t tLen = readlink(fullPathClean.fileSystemRepresentation, target, sizeof(target)-1);
      if (tLen < 0) continue;

      uint32_t uLen = (uint32_t)tLen;
      uLong crc = crc32(crc32(0L, Z_NULL, 0), (Bytef *)target, uLen);

      ZipLFH lfh = {0};
      lfh.sig = ZIP_LOCAL_FILE_SIG; lfh.versionNeeded = ZIP_VERSION_NEEDED;
      lfh.modTime = dt; lfh.modDate = dd;
      lfh.crc32Val = (uint32_t)crc;
      lfh.compressedSize = lfh.uncompressedSize = uLen;
      lfh.nameLen = nameLen;
      fwrite(&lfh, sizeof(lfh), 1, zf);
      fwrite(name, 1, nameLen, zf);
      fwrite(target, 1, uLen, zf);

      ZipCDH cdh = {0};
      cdh.sig = ZIP_CENTRAL_DIR_SIG; cdh.versionBy = ZIP_VERSION_BY;
      cdh.versionNeeded = ZIP_VERSION_NEEDED;
      cdh.modTime = dt; cdh.modDate = dd;
      cdh.crc32Val = (uint32_t)crc;
      cdh.compressedSize = cdh.uncompressedSize = uLen;
      cdh.nameLen = nameLen;
      // S_IFLNK (0xA000) in high 16 bits → unzip recognizes as symlink
      cdh.externalAttr = (unixMode << 16);
      cdh.localOffset = localOff;
      [cd appendBytes:&cdh length:sizeof(cdh)];
      [cd appendBytes:name length:nameLen];
      numEntries++;

    } else {
      // 普通文件 — STORE 模式，流式读写，CRC 在读取时累计
      FILE *src = fopen(fullPathClean.fileSystemRepresentation, "rb");
      if (!src) continue;

      fseeko(src, 0, SEEK_END);
      off_t fsize = ftello(src);
      fseeko(src, 0, SEEK_SET);
      if (fsize < 0) { fclose(src); continue; }

      uint32_t uLen = (uint32_t)MIN(fsize, (off_t)UINT32_MAX);

      // 先写 LFH (CRC 未知)，之后回填
      long lfhOff = ftell(zf);
      ZipLFH lfh = {0};
      lfh.sig = ZIP_LOCAL_FILE_SIG; lfh.versionNeeded = ZIP_VERSION_NEEDED;
      lfh.modTime = dt; lfh.modDate = dd;
      lfh.compressedSize = lfh.uncompressedSize = uLen;
      lfh.nameLen = nameLen;
      fwrite(&lfh, sizeof(lfh), 1, zf);
      fwrite(name, 1, nameLen, zf);

      // 流式写入文件内容，同时计算 CRC
      uLong crc = crc32(0L, Z_NULL, 0);
      uint32_t written = 0;
      while (written < uLen) {
        size_t toRead = (size_t)MIN((uint32_t)kBufSize, uLen - written);
        size_t got = fread(buf, 1, toRead, src);
        if (got == 0) break;
        crc = crc32(crc, buf, (uInt)got);
        fwrite(buf, 1, got, zf);
        written += (uint32_t)got;
      }
      fclose(src);

      // 回填 CRC 到 LFH
      long curPos = ftell(zf);
      fseek(zf, lfhOff + offsetof(ZipLFH, crc32Val), SEEK_SET);
      uint32_t crc32stored = (uint32_t)crc;
      fwrite(&crc32stored, 4, 1, zf);
      fseek(zf, curPos, SEEK_SET);

      ZipCDH cdh = {0};
      cdh.sig = ZIP_CENTRAL_DIR_SIG; cdh.versionBy = ZIP_VERSION_BY;
      cdh.versionNeeded = ZIP_VERSION_NEEDED;
      cdh.modTime = dt; cdh.modDate = dd;
      cdh.crc32Val = (uint32_t)crc;
      cdh.compressedSize = cdh.uncompressedSize = written;
      cdh.nameLen = nameLen;
      cdh.externalAttr = (unixMode << 16);
      cdh.localOffset = localOff;
      [cd appendBytes:&cdh length:sizeof(cdh)];
      [cd appendBytes:name length:nameLen];
      numEntries++;
    }
  }

  free(buf);

  uint32_t cdOffset = (uint32_t)ftell(zf);
  fwrite(cd.bytes, 1, cd.length, zf);

  ZipEOCD eocd = {0};
  eocd.sig = ZIP_END_CENTRAL_SIG;
  eocd.cdCount = eocd.cdCountTotal = numEntries;
  eocd.cdSize = (uint32_t)cd.length;
  eocd.cdOffset = cdOffset;
  fwrite(&eocd, sizeof(eocd), 1, zf);
  fclose(zf);

  NSLog(@"[ZipWriter] Done: %u entries → %@", numEntries, destPath);
  return YES;
}

// ─────────────────────────────────────────────────────────────────────────────
// createIPAAtPath:fromAppBundle:error:
// ─────────────────────────────────────────────────────────────────────────────
+ (BOOL)createIPAAtPath:(NSString *)ipaPath
          fromAppBundle:(NSString *)appPath
                  error:(NSError **)error {

  // ② 入参保护：appPath 为 nil 时 lastPathComponent 返回 nil，后续 stringByAppending... 崩溃
  if (!ipaPath.length || !appPath.length) {
    if (error) *error = [NSError errorWithDomain:@"ZipWriter" code:11 userInfo:@{
      NSLocalizedDescriptionKey: [NSString stringWithFormat:
          @"createIPA 路径参数为空 (ipa=%@, app=%@)", ipaPath ?: @"nil", appPath ?: @"nil"]}];
    return NO;
  }
  if (![[NSFileManager defaultManager] fileExistsAtPath:appPath]) {
    if (error) *error = [NSError errorWithDomain:@"ZipWriter" code:12 userInfo:@{
      NSLocalizedDescriptionKey: [NSString stringWithFormat:
          @"App Bundle 路径不存在: %@", appPath]}];
    return NO;
  }

  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *parentDir = [appPath stringByDeletingLastPathComponent];

  if ([[parentDir lastPathComponent] isEqualToString:@"Payload"]) {
    // 已在 /tmp/UUID/Payload/App.app — 直接从 /tmp/UUID/ 打包
    NSString *zipRoot = [parentDir stringByDeletingLastPathComponent];
    NSLog(@"[ZipWriter] createIPA from existing Payload: %@", zipRoot);
    return [self createZipAtPath:ipaPath fromDirectoryPath:zipRoot error:error];
  }

  // 创建临时 Payload 并复制
  NSString *tmpDir = [NSTemporaryDirectory()
      stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
  NSString *payloadDir = [tmpDir stringByAppendingPathComponent:@"Payload"];
  NSError *mkdirErr;
  if (![fm createDirectoryAtPath:payloadDir
         withIntermediateDirectories:YES attributes:nil error:&mkdirErr]) {
    if (error) *error = mkdirErr; return NO;
  }
  NSString *destApp = [payloadDir stringByAppendingPathComponent:
                       [appPath lastPathComponent]];
  NSError *copyErr;
  if (![fm copyItemAtPath:appPath toPath:destApp error:&copyErr]) {
    if (error) *error = copyErr;
    [fm removeItemAtPath:tmpDir error:nil]; return NO;
  }
  BOOL ok = [self createZipAtPath:ipaPath fromDirectoryPath:tmpDir error:error];
  [fm removeItemAtPath:tmpDir error:nil];
  return ok;
}

@end
