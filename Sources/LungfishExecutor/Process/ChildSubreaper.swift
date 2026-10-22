// ChildSubreaper.swift - The one Swift caller of the executor's C wrapper of prctl(PR_SET_CHILD_SUBREAPER)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CLungfishExecutor
import Foundation

/// The Linux child subreaper call, through `CLungfishExecutor`.
///
/// `prctl` is variadic in glibc and musl, and Swift imports no C variadic function, so a one-file C target holds a
/// non-variadic wrapper (SWIFT ruling N4). Each call returns 0 on success and else the `errno` value, and `ENOSYS` off
/// Linux, so Swift never reads `errno`. Only the executable's `main` calls `set()`, after it blocks the termination
/// signals and before any thread or child exists, so a test process never becomes a subreaper (tally-r2 K3-1).
enum ChildSubreaper {
    /// What one `set()` and the `get()` after it reported.
    struct Report: Equatable, Sendable {
        /// The setter's return, 0 or an errno value.
        var setterResult: Int32
        /// The getter's return, 0 or an errno value.
        var getterResult: Int32
        /// The getter's value, 1 when the process is a subreaper, nil when the getter failed.
        var getterValue: Int32?

        /// True only when the setter succeeded and the getter read 1.
        var isSet: Bool { setterResult == 0 && getterResult == 0 && getterValue == 1 }
    }

    /// Makes the calling process a child subreaper. Returns 0 or the errno value.
    static func set() -> Int32 {
        lungfish_set_child_subreaper()
    }

    /// Reads the calling process's subreaper state. Returns the call's result and, when it is 0, the value.
    static func get() -> (result: Int32, value: Int32?) {
        var value: Int32 = 0
        let result = lungfish_get_child_subreaper(&value)
        return (result, result == 0 ? value : nil)
    }

    /// Calls the setter, then the getter, and reports both.
    static func setAndConfirm() -> Report {
        let setter = set()
        let getter = get()
        return Report(setterResult: setter, getterResult: getter.result, getterValue: getter.value)
    }

    /// The symbolic name of an errno value the two calls can return, such as `EINVAL`, or `errno <n>`.
    static func errnoName(_ code: Int32) -> String {
        switch code {
        case 0: return "0"
        case EPERM: return "EPERM"
        case EINVAL: return "EINVAL"
        case EFAULT: return "EFAULT"
        case EACCES: return "EACCES"
        case ENOSYS: return "ENOSYS"
        default: return "errno \(code)"
        }
    }
}
