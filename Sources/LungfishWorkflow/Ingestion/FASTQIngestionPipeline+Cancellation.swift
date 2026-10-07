// FASTQIngestionPipeline+Cancellation.swift - In-process import work that stops when its caller is cancelled
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension FASTQIngestionPipeline {

    /// Runs blocking work off the cooperative pool, as `Task.detached` does,
    /// and forwards the caller's cancellation to it, which a detached task
    /// does not inherit.
    ///
    /// The import's in-process work polls `Task.checkCancellation()` as it
    /// reads. That is the join of a run's third file, the scans that find
    /// which records of one file are mates, the split by name and the record
    /// counts. In a plain detached task those polls never saw a cancel, so a
    /// cancelled import read its files to the end first. `lungfish-cli`
    /// turns SIGTERM into a cancel, and the app's runner sends SIGKILL five
    /// seconds later, so a CLI still busy in such work was killed before
    /// its cleanup ran and left its workspace and staging bundle behind (F9
    /// re-review N5, MSA session follow-up). A caller cancelled before the
    /// work starts gets `CancellationError` at once.
    static func detachedWork<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility, operation: work)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
