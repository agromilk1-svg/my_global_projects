//
//  dump.c
//  ECMAIN
//
//  动态脱壳模块 - 注入到目标 App 后自动执行
//  日志输出到: /var/mobile/Documents/ECMAINDump/dump.log
//

#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syslimits.h> // for PATH_MAX
#include <time.h>
#include <unistd.h>

// 日志文件句柄
static FILE *log_file = NULL;
static const char *DUMP_DIR = "/var/mobile/Documents/ECMAINDump";

// 初始化日志
void init_log(void) {
  // 确保目录存在
  mkdir(DUMP_DIR, 0755);

  char log_path[PATH_MAX];
  snprintf(log_path, sizeof(log_path), "%s/dump.log", DUMP_DIR);

  // 追加模式打开日志
  log_file = fopen(log_path, "a");
  if (log_file) {
    // 写入时间戳
    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    fprintf(
        log_file,
        "\n========== Dump Start: %04d-%02d-%02d %02d:%02d:%02d ==========\n",
        t->tm_year + 1900, t->tm_mon + 1, t->tm_mday, t->tm_hour, t->tm_min,
        t->tm_sec);
    fflush(log_file);
  }
}

// 日志输出函数
void log_msg(const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);

  // 同时输出到 stdout 和日志文件
  va_list args_copy;
  va_copy(args_copy, args);
  vprintf(fmt, args);
  printf("\n");

  if (log_file) {
    vfprintf(log_file, fmt, args_copy);
    fprintf(log_file, "\n");
    fflush(log_file);
  }

  va_end(args_copy);
  va_end(args);
}

// 关闭日志
void close_log(void) {
  if (log_file) {
    fprintf(log_file, "========== Dump End ==========\n");
    fclose(log_file);
    log_file = NULL;
  }
}

// 获取共享输出目录路径
const char *get_documents_path(void) {
  static char path[PATH_MAX];
  snprintf(path, sizeof(path), "%s", DUMP_DIR);
  mkdir(path, 0755);
  return path;
}

// 查找并修复 cryptid
void dump_binary(void) {
  log_msg("[Dump] Started...");
  log_msg("[Dump] PID: %d, UID: %d", getpid(), getuid());

  // 1. 获取主程序 Header
  const struct mach_header_64 *header =
      (const struct mach_header_64 *)_dyld_get_image_header(0);
  if (!header) {
    log_msg("[Dump] Error: Cannot find main binary header");
    return;
  }
  log_msg("[Dump] Header found at: %p", header);

  if (header->magic != MH_MAGIC_64) {
    log_msg("[Dump] Error: Not a 64-bit Mach-O binary (magic=0x%x)",
            header->magic);
    return;
  }
  log_msg("[Dump] Magic: 0x%x (MH_MAGIC_64), ncmds: %u", header->magic,
          header->ncmds);

  // 2. 获取源文件路径
  const char *executable_path = _dyld_get_image_name(0);
  log_msg("[Dump] Executable path: %s", executable_path);

  // 3. 读取源文件
  int fd = open(executable_path, O_RDONLY);
  if (fd < 0) {
    log_msg("[Dump] Error: Cannot open executable file (errno=%d)", errno);
    return;
  }
  log_msg("[Dump] Opened executable file, fd=%d", fd);

  struct stat st;
  if (fstat(fd, &st) < 0) {
    close(fd);
    log_msg("[Dump] Error: fstat failed (errno=%d)", errno);
    return;
  }

  size_t file_size = st.st_size;
  log_msg("[Dump] File size: %zu bytes", file_size);

  uint8_t *file_buf = malloc(file_size);
  if (!file_buf) {
    close(fd);
    log_msg("[Dump] Error: malloc failed for %zu bytes", file_size);
    return;
  }
  log_msg("[Dump] Allocated buffer at %p", file_buf);

  ssize_t bytes_read = read(fd, file_buf, file_size);
  if (bytes_read != file_size) {
    free(file_buf);
    close(fd);
    log_msg("[Dump] Error: read failed, expected %zu, got %zd", file_size,
            bytes_read);
    return;
  }
  close(fd);
  log_msg("[Dump] Read %zd bytes from file", bytes_read);

  // 4. 解析 Load Commands 查找 LC_ENCRYPTION_INFO
  struct mach_header_64 *buf_header = (struct mach_header_64 *)file_buf;
  uint8_t *cmd_ptr = file_buf + sizeof(struct mach_header_64);

  struct encryption_info_command_64 *crypt_cmd = NULL;

  log_msg("[Dump] Scanning %u load commands...", buf_header->ncmds);
  for (uint32_t i = 0; i < buf_header->ncmds; i++) {
    struct load_command *cmd = (struct load_command *)cmd_ptr;

    if (cmd->cmd == LC_ENCRYPTION_INFO_64) {
      crypt_cmd = (struct encryption_info_command_64 *)cmd;
      log_msg("[Dump] Found LC_ENCRYPTION_INFO_64 at cmd[%u]", i);
      break;
    }

    cmd_ptr += cmd->cmdsize;
  }

  if (!crypt_cmd) {
    log_msg(
        "[Dump] LC_ENCRYPTION_INFO_64 not found, binary may not be encrypted");
  } else {
    log_msg("[Dump] Encryption info: cryptid=%d, offset=0x%x, size=0x%x",
            crypt_cmd->cryptid, crypt_cmd->cryptoff, crypt_cmd->cryptsize);

    if (crypt_cmd->cryptid == 1) {
      // 5. 从内存复制解密后的数据
      uintptr_t memory_base = (uintptr_t)header;
      void *decrypted_ptr = (void *)(memory_base + crypt_cmd->cryptoff);

      log_msg("[Dump] Memory base: %p, decrypted data at: %p",
              (void *)memory_base, decrypted_ptr);
      log_msg("[Dump] Copying %u bytes of decrypted data...",
              crypt_cmd->cryptsize);

      // 替换 buffer 中的加密数据
      memcpy(file_buf + crypt_cmd->cryptoff, decrypted_ptr,
             crypt_cmd->cryptsize);

      // 6. 将 cryptid 设为 0
      crypt_cmd->cryptid = 0;
      log_msg("[Dump] Patched cryptid to 0");
    } else {
      log_msg("[Dump] Binary is not encrypted (cryptid=0)");
    }
  }

  // 7. 写入新文件
  char output_path[PATH_MAX];
  snprintf(output_path, sizeof(output_path), "%s/decrypted.bin",
           get_documents_path());

  log_msg("[Dump] Writing to: %s", output_path);

  // 如果文件已存在，先删除
  unlink(output_path);

  fd = open(output_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) {
    log_msg("[Dump] Error: Cannot create output file (errno=%d)", errno);
    free(file_buf);
    return;
  }

  ssize_t written = write(fd, file_buf, file_size);
  close(fd);

  if (written == file_size) {
    log_msg("[Dump] SUCCESS! Wrote %zd bytes to output file", written);

    // 验证文件
    struct stat out_st;
    if (stat(output_path, &out_st) == 0) {
      log_msg("[Dump] Verified: output file size = %lld bytes",
              (long long)out_st.st_size);
    }
  } else {
    log_msg("[Dump] Error: write failed, expected %zu, wrote %zd (errno=%d)",
            file_size, written, errno);
  }

  free(file_buf);

  // 8. 关闭日志并退出
  log_msg("[Dump] Exiting process...");
  close_log();

  exit(0);
}

__attribute__((constructor)) void entry(void) {
  init_log();
  log_msg("[Dump] ========================================");
  log_msg("[Dump] Dylib loaded! Constructor called.");
  log_msg("[Dump] ========================================");
  dump_binary();
}
