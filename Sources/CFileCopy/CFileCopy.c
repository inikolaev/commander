#include "CFileCopy.h"
#include <sys/types.h>
#include <copyfile.h>
#include <errno.h>

struct progress_context {
    commander_copy_progress progress;
    void *context;
    int64_t completed;
    int64_t current;
    int error;
};

static int report_progress(int what, int stage, copyfile_state_t state,
                           const char *source, const char *destination, void *raw) {
    (void)source; (void)destination;
    struct progress_context *context = raw;
    if (stage == COPYFILE_ERR) {
        context->error = errno ? errno : EIO;
        return COPYFILE_QUIT;
    }
    if (what == COPYFILE_RECURSE_FILE && stage == COPYFILE_START) {
        context->current = 0;
    } else if (what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS) {
        off_t copied = 0;
        if (copyfile_state_get(state, COPYFILE_STATE_COPIED, &copied) < 0) {
            context->error = errno ? errno : EIO;
            return COPYFILE_QUIT;
        }
        if (copied > context->current) context->current = copied;
    } else if (what == COPYFILE_RECURSE_FILE && stage == COPYFILE_FINISH) {
        context->completed += context->current;
        context->current = 0;
    }
    if (context->progress(context->completed + context->current, context->context)) {
        context->error = ECANCELED;
        return COPYFILE_QUIT;
    }
    return COPYFILE_CONTINUE;
}

int commander_copy_file(const char *source, const char *destination, int recursive,
                        commander_copy_progress progress, void *context) {
    copyfile_state_t state = copyfile_state_alloc();
    if (!state) return ENOMEM;
    struct progress_context wrapper = { progress, context, 0, 0, 0 };
    if (copyfile_state_set(state, COPYFILE_STATE_STATUS_CB, report_progress) < 0 ||
        copyfile_state_set(state, COPYFILE_STATE_STATUS_CTX, &wrapper) < 0) {
        int error = errno;
        copyfile_state_free(state);
        return error;
    }
    int flags = COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC;
    if (recursive) flags |= COPYFILE_RECURSIVE;
    int result = copyfile(source, destination, state, flags);
    int error = wrapper.error ? wrapper.error : (result < 0 ? errno : 0);
    copyfile_state_free(state);
    return error;
}
