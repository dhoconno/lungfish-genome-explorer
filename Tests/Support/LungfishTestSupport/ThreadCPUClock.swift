// ThreadCPUClock.swift - CPU time of the calling thread, for performance budgets
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin

/// Returns the CPU time the calling thread has used so far.
///
/// A performance budget read on this clock counts only the time the thread
/// ran on a core. Wall time also counts the time the thread waited for a core,
/// so other builds and test processes loading the machine can push a
/// wall-time budget past its limit while the code under test did no extra
/// work. A budget on this clock holds under that load, and slower work, such
/// as an extra pass, an extra full reload or a slower algorithm, still fails it.
///
/// Read it on the thread that does the work, before and after, and subtract.
/// Work on other threads and time spent blocked are not counted, so keep the
/// test's exact counts beside a CPU-time budget, and add a generous wall-time
/// ceiling where the latency itself matters.
public func currentThreadCPUTime() -> Duration {
    .nanoseconds(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID))
}
