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
///
/// Every base of every record counts (W-8). A record keeps its G+C and its A+C+G+T, in either case, and N or any other
/// code counts in neither. The bar's GC Content is the sum of G+C over the sum of A+C+G+T, so a long record weighs by
/// its length, as a GC content of the whole file does.
enum FASTACollectionGC {
    /// A record's base counts.
    struct Composition: Sendable, Equatable {
        var gc = 0
        var acgt = 0

        /// The GC percent, or nil for a record with no A, C, G or T.
        var percent: Double? {
            acgt > 0 ? Double(gc) / Double(acgt) * 100 : nil
        }
    }

    /// What a finished pass delivers.
    struct Result: Sendable {
        /// Each record's counts, keyed by sequence ID.
        let compositions: [UUID: Composition]
        /// The bar's GC Content, nil when no record has an A, C, G or T.
        let listPercent: Double?
    }

    /// Bases read at a time, so a long record never builds one huge string and a cancel ends it within a chunk.
    static let chunkLength = 1 << 20

    /// Counts every record, or answers nil when the task is cancelled first.
    static func count(_ sequences: [LungfishCore.Sequence]) -> Result? {
        var compositions = [UUID: Composition](minimumCapacity: sequences.count)
        var total = Composition()
        for sequence in sequences {
            guard let composition = composition(of: sequence) else { return nil }
            compositions[sequence.id] = composition
            total.gc += composition.gc
            total.acgt += composition.acgt
        }
        return Result(compositions: compositions, listPercent: total.percent)
    }

    /// Counts every base of one record, or answers nil when the task is cancelled first.
    static func composition(of sequence: LungfishCore.Sequence) -> Composition? {
        var counts = Composition()
        var start = 0
        repeat {
            if Task.isCancelled { return nil }
            let end = min(start + chunkLength, sequence.length)
            for byte in sequence[start..<end].utf8 {
                switch byte {
                case UInt8(ascii: "G"), UInt8(ascii: "g"), UInt8(ascii: "C"), UInt8(ascii: "c"):
                    counts.gc += 1
                    counts.acgt += 1
                case UInt8(ascii: "A"), UInt8(ascii: "a"), UInt8(ascii: "T"), UInt8(ascii: "t"):
                    counts.acgt += 1
                default:
                    break
                }
            }
            start = end
        } while start < sequence.length
        return counts
    }
}
