// EsVirituProgressParser.swift - Progress lines from EsViritu's stderr
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Turns EsViritu's stderr, one line at a time, into the run's progress lines.
///
/// EsViritu logs `Starting <step>...` as each of its steps begins and nothing more until the
/// step ends. Its first step after filtering runs minimap2 against the whole viral database, which
/// takes hours for a large sample rich in one virus. minimap2 prints `mapped <n> sequences` after
/// each batch of reads, so each batch becomes a line with the running read count. Without those
/// lines the run looked stalled at quality filtering for its whole alignment.
struct EsVirituProgressParser: Sendable {

    /// The fraction and message of one progress line.
    struct Update: Equatable, Sendable {
        let fraction: Double
        let message: String
    }

    /// EsViritu's steps in run order, by the function name its log prints. minimap2_f is
    /// handled apart, because EsViritu aligns three times.
    private static let steps: [String: Update] = [
        "trim_filter": Update(fraction: 0.20, message: "Quality filtering reads..."),
        "fastp_stats": Update(fraction: 0.25, message: "Counting the reads that passed filtering..."),
        "assembly_read_sharing_table": Update(fraction: 0.50, message: "Comparing the reads that viral references share..."),
        "cluster_assemblies_by_read_sharing": Update(fraction: 0.52, message: "Grouping viral references that share reads..."),
        "clust_record_getter": Update(fraction: 0.54, message: "Selecting one reference for each group..."),
        "bam_to_consensus_fasta": Update(fraction: 0.65, message: "Building consensus sequences..."),
        "bam_to_coverm_table": Update(fraction: 0.70, message: "Calculating coverage statistics..."),
        "bam_coverage_windows": Update(fraction: 0.74, message: "Calculating coverage along each genome..."),
        "consensus_lca_taxonomy": Update(fraction: 0.77, message: "Assigning taxonomy to consensus sequences..."),
        "assembly_table_maker": Update(fraction: 0.80, message: "Writing the detection tables..."),
        "tax_profile": Update(fraction: 0.82, message: "Building taxonomic profile..."),
    ]

    /// Fractions of the three alignment rounds. The first, against the whole database, is the
    /// long one.
    private static let alignmentFractions: [Double] = [0.30, 0.56, 0.60]

    private var fraction = 0.15
    private var alignmentRound = 0
    private var readsAligned = 0

    /// The progress line for `line`, or nil when the line reports no step and no aligned batch.
    mutating func update(for line: String) -> Update? {
        if let step = Self.startedStep(in: line) {
            if step == "minimap2_f" {
                alignmentRound += 1
                readsAligned = 0
                let index = min(alignmentRound, Self.alignmentFractions.count) - 1
                fraction = max(fraction, Self.alignmentFractions[index])
                return Update(fraction: fraction, message: alignmentMessage())
            }
            if let known = Self.steps[step] {
                fraction = max(fraction, known.fraction)
                return Update(fraction: fraction, message: known.message)
            }
            return Update(fraction: fraction, message: "Running the EsViritu step \(step)...")
        }
        if alignmentRound > 0, let count = Self.mappedSequenceCount(in: line) {
            readsAligned += count
            return Update(fraction: fraction, message: alignmentMessage())
        }
        if line.contains("generating reactable report") {
            fraction = max(fraction, 0.84)
            return Update(fraction: fraction, message: "Writing the EsViritu HTML report...")
        }
        return nil
    }

    private func alignmentMessage() -> String {
        let round = "Aligning reads to viral references (round \(alignmentRound))"
        guard readsAligned > 0 else { return round + "..." }
        let count = readsAligned.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
        return round + ": \(count) reads processed..."
    }

    /// The step name in EsViritu's `Starting <step>...` line, which may carry color codes.
    private static func startedStep(in line: String) -> String? {
        guard let start = line.range(of: "Starting "),
              let end = line.range(of: "...", range: start.upperBound..<line.endIndex)
        else { return nil }
        let step = line[start.upperBound..<end.lowerBound]
        guard !step.isEmpty, step.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return String(step)
    }

    /// The batch size in minimap2's `[M::worker_pipeline::<time>] mapped <n> sequences` line.
    private static func mappedSequenceCount(in line: String) -> Int? {
        guard line.contains("[M::worker_pipeline"),
              let mapped = line.range(of: "] mapped "),
              let sequences = line.range(of: " sequences", range: mapped.upperBound..<line.endIndex)
        else { return nil }
        return Int(line[mapped.upperBound..<sequences.lowerBound])
    }
}
