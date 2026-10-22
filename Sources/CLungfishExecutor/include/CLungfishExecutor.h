// CLungfishExecutor.h - The child subreaper wrapper of the Linux executor lungfish-executor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

#pragma once

// Each function returns 0 on success and else the errno value the call set, so Swift never reads errno. Off Linux
// both return ENOSYS.

// Makes the calling process a child subreaper (prctl PR_SET_CHILD_SUBREAPER), so an orphaned descendant re-parents to it.
int lungfish_set_child_subreaper(void);

// Writes the calling process's child subreaper state (prctl PR_GET_CHILD_SUBREAPER) to *out, 1 when set and 0 when not.
int lungfish_get_child_subreaper(int *out);
