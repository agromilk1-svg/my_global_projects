// ZipReader.h - Minimal ZIP file reader using zlib (replaces libarchive for IPA
// reading)
#import <Foundation/Foundation.h>

// Forward declarations for archive compatibility
struct archive;
struct archive_entry;

// Create a new archive reader
struct archive *archive_read_new(void);

// Support functions
int archive_read_support_format_all(struct archive *);
int archive_read_support_filter_all(struct archive *);
int archive_read_open_filename(struct archive *, const char *filename,
                               size_t block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *buffer, size_t len);
int archive_read_close(struct archive *);
int archive_read_free(struct archive *);

// Entry functions
const char *archive_entry_pathname(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);

// Error functions
const char *archive_error_string(struct archive *);

// Constants
#define ARCHIVE_OK 0
#define ARCHIVE_EOF 1
#define ARCHIVE_WARN -20
#define ARCHIVE_FAILED -25
#define ARCHIVE_FATAL -30
