// FASTACollectionGCPass.swift - Counts the FASTA list's GC off the main thread
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Counts each record's GC for the FASTA list off the main thread (W-34).
///
/// `configure` used to count every record on the main thread, which held the app for 12 s at 20,000 records in Debug.
/// The pass runs in a detached task instead. Each start takes a new generation, so a pass for an older list never
/// delivers into a newer one, and the older task stops at its next record.
@MainActor
final class FASTACollectionGCPass {
    private var generation = 0
    private var task: Task<Void, Never>?

    isolated deinit {
        task?.cancel()
    }

    /// Starts counting `sequences` and ends any pass still running. `deliver` runs on the main actor once every record
    /// is counted, and only while no newer pass has started.
    func start(
        _ sequences: [LungfishCore.Sequence],
        deliver: @escaping @MainActor @Sendable (FASTACollectionGC.Result) -> Void
    ) {
        task?.cancel()
        generation &+= 1
        let current = generation
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let result = FASTACollectionGC.count(sequences) else { return }
            await self?.finish(result, generation: current, deliver: deliver)
        }
    }

    private func finish(
        _ result: FASTACollectionGC.Result,
        generation finished: Int,
        deliver: @MainActor (FASTACollectionGC.Result) -> Void
    ) {
        guard finished == generation else { return }
        task = nil
        deliver(result)
    }
}

/// The list's GC counts. Free of any actor, so the pass runs them off the main thread.
enum FASTACollectionGC {
    /// What a finished pass delivers.
    struct Result: Sendable {
        /// Each record's GC percent, keyed by sequence ID.
        let percents: [UUID: Double]
        /// The bar's GC Content.
        let listPercent: Double?
    }

    /// Counts every record, or answers nil when the task is cancelled first.
    static func count(_ sequences: [LungfishCore.Sequence]) -> Result? {
        var percents = [UUID: Double](minimumCapacity: sequences.count)
        var sum = 0.0
        for sequence in sequences {
            if Task.isCancelled { return nil }
            let percent = percent(of: sequence)
            percents[sequence.id] = percent
            sum += percent
        }
        return Result(percents: percents, listPercent: sequences.isEmpty ? nil : sum / Double(sequences.count))
    }

    /// Computes GC percentage for a sequence by sampling up to 10,000 bases.
    ///
    /// For sequences longer than 10,000 bp, samples evenly-spaced windows
    /// to keep computation bounded.
    static func percent(of seq: LungfishCore.Sequence) -> Double {
        let length = seq.length
        guard length > 0 else { return 0 }

        let sampleSize = min(length, 10_000)
        var gcCount = 0
        var totalCount = 0

        if length <= sampleSize {
            // Sample entire sequence
            let bases = seq[0..<length]
            for base in bases {
                switch base {
                case "G", "g", "C", "c":
                    gcCount += 1
                    totalCount += 1
                case "A", "a", "T", "t":
                    totalCount += 1
                default:
                    break // Skip N and ambiguous bases
                }
            }
        } else {
            // Sample evenly-spaced windows
            let windowSize = 100
            let windowCount = sampleSize / windowSize
            let step = length / windowCount

            for i in 0..<windowCount {
                let start = i * step
                let end = min(start + windowSize, length)
                let bases = seq[start..<end]
                for base in bases {
                    switch base {
                    case "G", "g", "C", "c":
                        gcCount += 1
                        totalCount += 1
                    case "A", "a", "T", "t":
                        totalCount += 1
                    default:
                        break
                    }
                }
            }
        }

        guard totalCount > 0 else { return 0 }
        return Double(gcCount) / Double(totalCount) * 100.0
    }
}
