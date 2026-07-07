// DownloadTaskCancellationBox.swift - lock-backed URLSession cancellation bridge
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os

final class DownloadTaskCancellationBox: @unchecked Sendable {
    private struct State {
        var task: URLSessionDownloadTask?
        var cancelled = false
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    func store(_ task: URLSessionDownloadTask) {
        let shouldCancel = lock.withLock { state in
            state.task = task
            return state.cancelled
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        let task = lock.withLock { state in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }
}
