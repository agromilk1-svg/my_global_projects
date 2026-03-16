// ZipReader.m - Minimal ZIP file reader using zlib (replaces libarchive for IPA
// reading)
#import "ZipReader.h"
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <zlib.h>

#define ZIP_LOCAL_FILE_SIG 0x04034b50
#define ZIP_CENTRAL_DIR_SIG 0x02014b50
#define ZIP_END_CENTRAL_SIG 0x06054b50
#define MAX_ENTRIES 10000

#pragma pack(push, 1)
typedef struct {
  uint32_t signature;
  uint16_t version;
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
#pragma pack(pop)

// Internal entry structure
typedef struct archive_entry_internal {
  char *pathname;
  int64_t size;
  int64_t compressedSize;
  uint16_t compression;
  long dataOffset; // Offset to compressed data in file
} ArchiveEntryInternal;

// Internal archive structure
typedef struct archive_internal {
  FILE *file;
  char *filename;
  char *errorString;

  ArchiveEntryInternal *entries;
  int entryCount;
  int currentEntry;

  void *currentData;
  size_t currentDataSize;
} ArchiveInternal;

struct archive *archive_read_new(void) {
  ArchiveInternal *a = calloc(1, sizeof(ArchiveInternal));
  a->entries = calloc(MAX_ENTRIES, sizeof(ArchiveEntryInternal));
  a->currentEntry = -1;
  return (struct archive *)a;
}

int archive_read_support_format_all(struct archive *_a) { return ARCHIVE_OK; }

int archive_read_support_filter_all(struct archive *_a) { return ARCHIVE_OK; }

int archive_read_open_filename(struct archive *_a, const char *filename,
                               size_t block_size) {
  ArchiveInternal *a = (ArchiveInternal *)_a;

  a->file = fopen(filename, "rb");
  if (!a->file) {
    a->errorString = "Failed to open file";
    return ARCHIVE_FATAL;
  }

  a->filename = strdup(filename);
  a->entryCount = 0;

  // Scan all local file headers
  while (!feof(a->file) && a->entryCount < MAX_ENTRIES) {
    ZipLocalFileHeader header;
    long headerPos = ftell(a->file);

    if (fread(&header, sizeof(header), 1, a->file) != 1)
      break;

    if (header.signature == ZIP_LOCAL_FILE_SIG) {
      ArchiveEntryInternal *entry = &a->entries[a->entryCount];

      // Read filename
      entry->pathname = malloc(header.fileNameLength + 1);
      fread(entry->pathname, 1, header.fileNameLength, a->file);
      entry->pathname[header.fileNameLength] = '\0';

      // Skip extra field
      fseek(a->file, header.extraFieldLength, SEEK_CUR);

      // Store entry info
      entry->dataOffset = ftell(a->file);
      entry->size = header.uncompressedSize;
      entry->compressedSize = header.compressedSize;
      entry->compression = header.compression;

      // Skip data
      fseek(a->file, header.compressedSize, SEEK_CUR);

      a->entryCount++;
    } else if (header.signature == ZIP_CENTRAL_DIR_SIG ||
               header.signature == ZIP_END_CENTRAL_SIG) {
      break;
    } else {
      // Unknown signature, try to recover
      fseek(a->file, headerPos + 1, SEEK_SET);
    }
  }

  // Reset for reading
  a->currentEntry = -1;

  return ARCHIVE_OK;
}

int archive_read_next_header(struct archive *_a, struct archive_entry **entry) {
  ArchiveInternal *a = (ArchiveInternal *)_a;

  // Free previous data
  if (a->currentData) {
    free(a->currentData);
    a->currentData = NULL;
  }

  a->currentEntry++;

  if (a->currentEntry >= a->entryCount) {
    return ARCHIVE_EOF;
  }

  *entry = (struct archive_entry *)&a->entries[a->currentEntry];
  return ARCHIVE_OK;
}

const char *archive_entry_pathname(struct archive_entry *_entry) {
  ArchiveEntryInternal *entry = (ArchiveEntryInternal *)_entry;
  return entry->pathname;
}

int64_t archive_entry_size(struct archive_entry *_entry) {
  ArchiveEntryInternal *entry = (ArchiveEntryInternal *)_entry;
  return entry->size;
}

ssize_t archive_read_data(struct archive *_a, void *buffer, size_t len) {
  ArchiveInternal *a = (ArchiveInternal *)_a;

  if (a->currentEntry < 0 || a->currentEntry >= a->entryCount) {
    return -1;
  }

  ArchiveEntryInternal *entry = &a->entries[a->currentEntry];

  // Seek to data
  fseek(a->file, entry->dataOffset, SEEK_SET);

  // Read compressed data
  void *compressedData = malloc(entry->compressedSize);
  size_t readSize = fread(compressedData, 1, entry->compressedSize, a->file);

  if (readSize != entry->compressedSize) {
    free(compressedData);
    return -1;
  }

  size_t outputSize = 0;

  if (entry->compression == 0) {
    // Stored (no compression)
    outputSize = (len < entry->size) ? len : entry->size;
    memcpy(buffer, compressedData, outputSize);
  } else if (entry->compression == 8) {
    // Deflate
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    strm.next_in = compressedData;
    strm.avail_in = (uInt)entry->compressedSize;
    strm.next_out = buffer;
    strm.avail_out = (uInt)len;

    if (inflateInit2(&strm, -MAX_WBITS) == Z_OK) {
      int ret = inflate(&strm, Z_FINISH);
      if (ret == Z_STREAM_END || ret == Z_OK) {
        outputSize = strm.total_out;
      }
      inflateEnd(&strm);
    }
  }

  free(compressedData);
  return outputSize;
}

int archive_read_close(struct archive *_a) {
  ArchiveInternal *a = (ArchiveInternal *)_a;
  if (a->file) {
    fclose(a->file);
    a->file = NULL;
  }
  return ARCHIVE_OK;
}

int archive_read_free(struct archive *_a) {
  ArchiveInternal *a = (ArchiveInternal *)_a;

  if (a->file) {
    fclose(a->file);
  }

  if (a->filename) {
    free(a->filename);
  }

  if (a->currentData) {
    free(a->currentData);
  }

  // Free entry pathnames
  for (int i = 0; i < a->entryCount; i++) {
    if (a->entries[i].pathname) {
      free(a->entries[i].pathname);
    }
  }

  if (a->entries) {
    free(a->entries);
  }

  free(a);
  return ARCHIVE_OK;
}

const char *archive_error_string(struct archive *_a) {
  ArchiveInternal *a = (ArchiveInternal *)_a;
  return a->errorString ? a->errorString : "Unknown error";
}
