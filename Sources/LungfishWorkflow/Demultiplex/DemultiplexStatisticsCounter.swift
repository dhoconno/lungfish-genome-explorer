// DemultiplexStatisticsCounter.swift - Every statistic of the reads a Swift demultiplexer assigns, counted as it reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Counts the reads of each output group (a sample, a barcode, or the unassigned reads) with one
/// `FASTQStatisticsCollector` a group, in the pass that assigns them, so a bundle stores the lengths, scores and GC
/// of the reads it holds. The exact routes stored 0 for mean Q, Q20, Q30 and GC before (Phase 3.0 lane DEMUX-STATS,
/// walk WF-8b).
///
/// The scores are decoded with the encoding the first read shows, as `FASTQReader` decodes a file. One task uses an
/// instance at a time: a worker of a multi-file root counts its file in its own instance, and the parent merges it
/// only after the worker's task has returned, so the instance is never shared while it changes.
final class DemultiplexStatisticsCounter<Group: Hashable>: @unchecked Sendable {
    private var collectors: [Group: FASTQStatisticsCollector] = [:]
    private var encoding: QualityEncoding?

    /// Counts `record` in `group`. The collector reads only the sequence and the scores.
    func count(_ record: FASTQRawRecord, in group: Group) {
        let encoding = self.encoding ?? QualityEncoding.detect(from: record.quality)
        self.encoding = encoding
        let collector: FASTQStatisticsCollector
        if let existing = collectors[group] {
            collector = existing
        } else {
            collector = FASTQStatisticsCollector()
            collectors[group] = collector
        }
        collector.process(FASTQRecord(
            identifier: "",
            sequence: record.sequence,
            qualityString: record.quality,
            encoding: encoding
        ))
    }

    /// Adds every group `other` counted, a counter that read later records, and empties `other`.
    func merge(_ other: DemultiplexStatisticsCounter<Group>) {
        for (group, collector) in other.collectors {
            if let existing = collectors[group] {
                existing.merge(collector)
            } else {
                collectors[group] = collector
            }
        }
        other.collectors.removeAll()
    }

    /// The statistics of every read counted in `group`, or `.empty` when it holds none.
    func statistics(of group: Group) -> FASTQDatasetStatistics {
        collectors[group]?.finalize() ?? .empty
    }
}
