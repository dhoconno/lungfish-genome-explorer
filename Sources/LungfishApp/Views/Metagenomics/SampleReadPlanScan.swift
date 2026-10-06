// SampleReadPlanScan.swift - Bounded, incremental per-sample read layout scan
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Scans the samples of a metagenomics wizard a few at a time and reports each
/// result as soon as it is ready, so the wizard can show progress instead of
/// waiting for every sample before publishing anything.
enum SampleReadPlanScan {
    /// Number of samples scanned at once. Each scan is mostly file reads, so
    /// half the cores (between 2 and 8) keeps the disk busy without thrashing.
    static var defaultWidth: Int {
        max(2, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    /// Yields `(sampleId, value)` as each sample finishes, with at most `width`
    /// scans running at once. Arrival order is not the input order. Ending the
    /// consuming task cancels the producer and stops new scans from starting.
    static func stream<Value: Sendable>(
        samples: [MetagenomicsSampleInput],
        width: Int = defaultWidth,
        work: @escaping @Sendable (MetagenomicsSampleInput) async -> Value
    ) -> AsyncStream<(String, Value)> {
        let limit = max(1, width)
        return AsyncStream { continuation in
            let producer = Task.detached(priority: .userInitiated) {
                await withTaskGroup(of: (String, Value).self) { group in
                    var iterator = samples.makeIterator()
                    func addNext() -> Bool {
                        guard !Task.isCancelled, let sample = iterator.next() else { return false }
                        group.addTask { (sample.sampleId, await work(sample)) }
                        return true
                    }
                    for _ in 0..<limit {
                        if !addNext() { break }
                    }
                    while let result = await group.next() {
                        continuation.yield(result)
                        _ = addNext()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}
