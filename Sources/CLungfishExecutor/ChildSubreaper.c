// ChildSubreaper.c - The child subreaper wrapper of the Linux executor lungfish-executor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

#include "CLungfishExecutor.h"

#include <errno.h>
#include <stddef.h>

#ifdef __linux__
#include <sys/prctl.h>

int lungfish_set_child_subreaper(void) {
    if (prctl(PR_SET_CHILD_SUBREAPER, 1UL, 0UL, 0UL, 0UL) == 0) {
        return 0;
    }
    return errno;
}

int lungfish_get_child_subreaper(int *out) {
    int value = 0;
    if (out == NULL) {
        return EINVAL;
    }
    if (prctl(PR_GET_CHILD_SUBREAPER, (unsigned long)&value, 0UL, 0UL, 0UL) == 0) {
        *out = value;
        return 0;
    }
    return errno;
}
#else
int lungfish_set_child_subreaper(void) {
    return ENOSYS;
}

int lungfish_get_child_subreaper(int *out) {
    (void)out;
    return ENOSYS;
}
#endif
