// LungfishTestObserverBootstrap.h - The constructor target that installs the test-state observer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

#ifndef LUNGFISH_TEST_OBSERVER_BOOTSTRAP_H
#define LUNGFISH_TEST_OBSERVER_BOOTSTRAP_H

/// Returns 1. The constructor in bootstrap.c does the work when the image loads. This symbol only lets a test show
/// that the target is linked into its bundle.
int LGETestObserverBootstrapIsLinked(void);

#endif
