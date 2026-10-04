// EsVirituPipeline+ReadSets.swift - EsViritu takes a sample's pairs as a pair and every other read in one file
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/contracts/READ-PAIRING.md is the contract. EsViritu 1.3.3 takes
// `-p paired` with exactly two files and `-p unpaired` or `-p interleaved`
// with exactly one. Given several files with `-p unpaired` it logs "must
// provide exactly 1 read file", writes no detection table and exits 0, so a
// paired derivative, a merge or repair derivative and a chunked root did not
// run. ``SamplesheetReadSetPlanner`` gives each of them the form EsViritu takes.

import Foundation
import LungfishIO

extension EsVirituConfig {

    /// The consumer ID EsViritu declares in ``ReadPairingCapabilityRegistry``.
    public static let readPairingConsumerID = "classify.esviritu"

    /// The plan for one input, a bundle or a file, as the app and
    /// `lungfish-cli esviritu detect --read-format auto` both make it. A
    /// virtual bundle already materialized into `materializedInputs` is not
    /// materialized again, and the files a join writes go into
    /// `materializationDirectory`.
    public static func readSet(
        for input: URL,
        materializedInputs: [URL],
        materializationDirectory: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SamplesheetReadSet {
        try await SamplesheetReadSetPlanner.plan(
            input: input,
            consumerID: readPairingConsumerID,
            materializedInputs: materializedInputs,
            materializationDirectory: materializationDirectory,
            progress: progress
        )
    }

    /// Sets the configuration's files, read format and layout from a planned
    /// sample, and records the plan and the files' lineage for provenance.
    ///
    /// - Separate R1 and R2 files run `-p paired`.
    /// - A sample that mixes pairs and single reads, and a sample of several
    ///   files of single reads, run `-p unpaired` on one file that holds every
    ///   read. A mixed sample says why in its plan.
    /// - A plain single-end file and one interleaved file are what the
    ///   configuration already runs, so they are left as they are.
    ///
    /// - Returns: Whether the plan changed the configuration.
    @discardableResult
    public mutating func apply(_ readSet: SamplesheetReadSet) -> Bool {
        switch readSet.reads {
        case .matePair(let r1, let r2):
            inputFiles = [r1, r2]
            adoptReadFormat(.paired)
            inputLayout = nil
        case .singleEnd(let file):
            guard readSet.changesTheRun else { return false }
            inputFiles = [file]
            adoptReadFormat(.unpaired)
            if readSet.plan.singleReadReason != nil, inputLayout?.layout != .mixedInterleaved {
                inputLayout = Self.mixedLayout(of: readSet.plan)
            }
        case .interleaved:
            return false
        }
        readSetPlan = readSet.plan
        recordInputLineage(readSet.resolvedInputs)
        return true
    }

    /// A layout record for a sample that mixes pairs and single reads and runs
    /// single-end, so the label and the saved result say so. A count the plan
    /// did not read is zero.
    static func mixedLayout(of plan: ReadSetPlan) -> FASTQReadLayoutClassification {
        let composition = plan.composition
        let pairs = composition.pairedFragments ?? 0
        let singleReads = [
            composition.mergedReads,
            composition.orphanReads,
            composition.singleEndReads,
            composition.mergedOrOrphanReads,
        ].reduce(0) { $0 + ($1 ?? 0) }
        return FASTQReadLayoutClassification(
            layout: .mixedInterleaved,
            scannedRecords: pairs * 2 + singleReads,
            matePairs: pairs,
            unpairedRecords: singleReads,
            scannedWholeFile: composition.fragmentCount != nil,
            metadata: FASTQPairingMetadataHints(hasMergedOrUnpairedReads: true),
            reason: plan.singleReadReason ?? plan.layoutReason
        )
    }

    /// The summary lines for the read format. A planned run that mixed pairs
    /// and single reads adds the reason every read ran single-end.
    func readFormatSummaryLines() -> [String] {
        var lines = [
            "  Read format: \(readFormat.rawValue) (\(EsVirituReadFormat.inputLabel(format: readFormat, layout: inputLayout?.layout)))",
        ]
        if let reason = readSetPlan?.singleReadReason {
            lines.append("  Read set: \(reason)")
        }
        return lines
    }
}
