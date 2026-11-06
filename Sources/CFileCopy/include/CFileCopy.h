#ifndef COMMANDER_FILE_COPY_H
#define COMMANDER_FILE_COPY_H
#include <stdint.h>
// Return nonzero to cancel. Returns an errno value, or zero on success.
typedef int (*commander_copy_progress)(int64_t copied, void *context);
int commander_copy_file(const char *source, const char *destination, int recursive,
                        commander_copy_progress progress, void *context);
#endif
