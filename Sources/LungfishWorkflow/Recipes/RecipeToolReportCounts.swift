// RecipeToolReportCounts.swift - read counts from the reports recipe tools write
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Read counts taken from the reports recipe tools write beside their output,
/// so the engine never reads a step's reads again just to count them.
///
/// Counts are in the engine's units: pairs for an R1/R2 step. A report that
/// lacks a figure, or whose figures do not add up, gives nil, and the engine
/// counts the lines of the step's output instead.
enum RecipeToolReportCounts {
    /// Pairs fastp read and wrote in paired mode, after any dedup.
    static func fastpPairs(reportAt url: URL) -> (input: Int, output: Int)? {
        guard let report = object(at: url),
              let input = totalReads(report["read1_before_filtering"]),
              let output = totalReads(report["read1_after_filtering"]) else {
            return nil
        }
        return (input, output)
    }

    /// fastp `--merge`: the pairs read, the merged reads, and the unmerged
    /// pairs written beside them. The report counts merged reads but not the
    /// unmerged pairs. Every pair that passes filtering is one or the other,
    /// and paired filtering passes or drops both mates, so the unmerged pairs
    /// are the passing pairs less the merged reads.
    static func fastpMerge(reportAt url: URL) -> (inputPairs: Int, mergedReads: Int, unmergedPairs: Int)? {
        guard let report = object(at: url),
              let inputPairs = totalReads(report["read1_before_filtering"]),
              let mergedReads = totalReads(report["merged_and_filtered"]),
              let passedReads = (report["filtering_result"] as? [String: Any])?["passed_filter_reads"] as? Int,
              passedReads % 2 == 0,
              passedReads / 2 <= inputPairs,
              mergedReads <= passedReads / 2 else {
            return nil
        }
        return (inputPairs, mergedReads, passedReads / 2 - mergedReads)
    }

    /// Pairs deacon read and kept. With two inputs its summary counts both
    /// mates of every pair.
    static func deaconPairs(summaryAt url: URL) -> (input: Int, output: Int)? {
        guard let summary = object(at: url),
              summary["input2"] is String,
              let seqsIn = summary["seqs_in"] as? Int,
              let seqsOut = summary["seqs_out"] as? Int,
              seqsIn % 2 == 0,
              seqsOut % 2 == 0 else {
            return nil
        }
        return (seqsIn / 2, seqsOut / 2)
    }

    private static func object(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func totalReads(_ section: Any?) -> Int? {
        (section as? [String: Any])?["total_reads"] as? Int
    }
}
