// SpawnWorkingDirectory.c - The working-directory file action of the Linux executor lungfish-executor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

// glibc and musl declare posix_spawn_file_actions_addchdir_np only for _GNU_SOURCE, and Swift's Glibc module does not
// import it, so this wrapper holds the one call (glibc 2.29, musl 1.1.24 and later).
#define _GNU_SOURCE

#include "CLungfishExecutor.h"

#include <errno.h>

#ifdef __linux__
#include <spawn.h>

int lungfish_spawn_file_actions_addchdir(void *actions, const char *path) {
    if (actions == NULL || path == NULL) {
        return EINVAL;
    }
    return posix_spawn_file_actions_addchdir_np((posix_spawn_file_actions_t *)actions, path);
}
#else
#include <stddef.h>

int lungfish_spawn_file_actions_addchdir(void *actions, const char *path) {
    (void)actions;
    (void)path;
    return ENOSYS;
}
#endif
