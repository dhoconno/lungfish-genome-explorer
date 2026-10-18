// BundleDecodeLane.swift - Large bundle decodes run one at a time, off the main actor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os

/// Runs the decodes of large bundle files one at a time, off the main actor.
///
/// The manifest of a large reference, and a mapping result onto it, is
/// hundreds of megabytes, and each decode peaks above 2 GB. `JSONDecoder`
/// cannot be cancelled, so the decode of a bundle the user has left runs to
/// its end, and quick clicks through such references ran their decodes side by
/// side, five of them near 11 GB. The lane runs one large decode at a time, so
/// a 16 GB Mac holds one decode's peak. The open that started a superseded
/// decode drops its result, and a waiting decode whose open was cancelled
/// never starts. Files of ``largeFileBytes`` or less decode at once, so a
/// small bundle never waits behind a large one.
actor BundleDecodeLane {
    static let shared = BundleDecodeLane()

    /// Files over this size wait for the lane.
    static let defaultLargeFileBytes: Int64 = 64 * 1024 * 1024

    private static let waiting = OSAllocatedUnfairLock(initialState: 0)

    #if DEBUG
    private static let largeFileBytesOverride = OSAllocatedUnfairLock<Int64?>(initialState: nil)

    /// Lets a test send small files through the lane. `nil` restores the default.
    static func overrideLargeFileBytes(_ bytes: Int64?) {
        largeFileBytesOverride.withLock { $0 = bytes }
    }
    #endif

    /// Files over this size wait for the lane.
    static var largeFileBytes: Int64 {
        #if DEBUG
        if let bytes = largeFileBytesOverride.withLock({ $0 }) { return bytes }
        #endif
        return defaultLargeFileBytes
    }

    /// How many large decodes wait for the one that runs.
    static var waitingCount: Int {
        waiting.withLock { $0 }
    }

    /// Runs `body` on a background thread and returns its outcome. Cancelling
    /// the caller cancels `body`, so a decode still waiting for the lane never
    /// starts. A decode that has started runs to its end.
    static func offMain<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async -> Result<T, Error> {
        let task = Task.detached(priority: .userInitiated) { () async -> Result<T, Error> in
            do {
                return .success(try await body())
            } catch {
                return .failure(error)
            }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Runs `work` in the lane when the first of `files` that exists is over
    /// ``largeFileBytes``, and at once otherwise.
    static func decode<T: Sendable>(
        reading files: [URL],
        _ work: @Sendable () throws -> T
    ) async throws -> T {
        guard isLarge(files) else { return try work() }
        waiting.withLock { $0 += 1 }
        return try await shared.run(work)
    }

    private func run<T: Sendable>(_ work: @Sendable () throws -> T) throws -> T {
        Self.waiting.withLock { $0 -= 1 }
        try Task.checkCancellation()
        return try work()
    }

    private static func isLarge(_ files: [URL]) -> Bool {
        for file in files {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                return Int64(size) > largeFileBytes
            }
        }
        return false
    }
}
