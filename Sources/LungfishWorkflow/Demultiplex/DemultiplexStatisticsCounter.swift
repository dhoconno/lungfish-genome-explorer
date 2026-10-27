// DemultiplexStatisticsCounter.swift - Every statistic of the reads a Swift demultiplexer assigns, counted as it reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import Synchronization

/// Counts the reads of each output group (a sample, a barcode, or the unassigned reads) with one
/// `FASTQStatisticsCollector` a group, in the pass that assigns them, so a bundle stores the lengths, scores and GC
/// of the reads it holds. The exact routes stored 0 for mean Q, Q20, Q30 and GC before (Phase 3.0 lane DEMUX-STATS,
/// walk WF-8b).
///
/// The scores are decoded with the encoding the first read shows, as `FASTQReader` decodes a file. A `Mutex` guards
/// the collectors and the encoding, so the counter is `Sendable` with no escape hatch: a worker of a multi-file root
/// counts its file in its own instance and the parent merges it after the worker has returned. A collector cannot leave
/// a `Mutex` (a `sending` result must not be connected to the guarded state), so `merge` moves the other counter's
/// sums as values (`FASTQStatisticsCollector.Accumulation`).
final class DemultiplexStatisticsCounter<Group: Hashable & Sendable>: Sendable {
    private struct State {
        var collectors: [Group: FASTQStatisticsCollector] = [:]
        var encoding: QualityEncoding?
    }

    private let guarded = Mutex(State())

    /// Counts `record` in `group`. The collector reads only the sequence and the scores.
    func count(_ record: FASTQRawRecord, in group: Group) {
        let sequence = record.sequence
        let quality = record.quality
        guarded.withLock { state in
            let encoding = state.encoding ?? QualityEncoding.detect(from: quality)
            state.encoding = encoding
            let collector: FASTQStatisticsCollector
            if let existing = state.collectors[group] {
                collector = existing
            } else {
                collector = FASTQStatisticsCollector()
                state.collectors[group] = collector
            }
            collector.process(FASTQRecord(
                identifier: "",
                sequence: sequence,
                qualityString: quality,
                encoding: encoding
            ))
        }
    }

    /// Adds every group `other` counted, a counter that read later records, and empties `other`. The sums of a group
    /// that is new here are added to an empty collector, which gives the same numbers as adopting the other's.
    func merge(_ other: DemultiplexStatisticsCounter<Group>) {
        let moved: [Group: FASTQStatisticsCollector.Accumulation] = other.guarded.withLock { state in
            let sums = state.collectors.mapValues { $0.accumulation() }
            state.collectors.removeAll()
            return sums
        }
        guarded.withLock { state in
            for (group, sums) in moved {
                let collector: FASTQStatisticsCollector
                if let existing = state.collectors[group] {
                    collector = existing
                } else {
                    collector = FASTQStatisticsCollector()
                    state.collectors[group] = collector
                }
                collector.merge(sums)
            }
        }
    }

    /// The statistics of every read counted in `group`, or `.empty` when it holds none.
    func statistics(of group: Group) -> FASTQDatasetStatistics {
        guarded.withLock { state in state.collectors[group]?.finalize() ?? .empty }
    }
}
