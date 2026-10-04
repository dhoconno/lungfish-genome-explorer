// TaxTriageReadSetPlanner.swift - TaxTriage takes a sample's pairs as fastq_1 and fastq_2 and every other read in one file
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/contracts/READ-PAIRING.md is the contract. TaxTriage reads pairs only
// through the samplesheet's fastq_1 and fastq_2 columns, one file each, and
// cannot pair part of a sample. The app's TaxTriage launch and
// `lungfish-cli taxtriage run` both resolve each sample here, so a recorded
// command plans a bundle exactly as the launch did.

import Foundation
import LungfishIO

public enum TaxTriageReadSetPlanner {

    /// The consumer ID TaxTriage declares in ``ReadPairingCapabilityRegistry``.
    public static let consumerID = "classify.taxtriage"

    /// The sample with its inputs resolved to the files TaxTriage reads.
    ///
    /// - One `.lungfishfastq` bundle (`fastq2` nil) is planned by
    ///   ``SamplesheetReadSetPlanner``. A sample of pairs only gives
    ///   `fastq_1` and `fastq_2`, a strictly interleaved file stays one file
    ///   for the pipeline to split, and a sample that mixes pairs and single
    ///   reads, or holds several files of single reads, gives one single-end
    ///   file that holds every read. A virtual bundle is materialized first.
    /// - A sample that names two inputs as R1 and R2 reads each as one file,
    ///   and refuses a bundle that is not one file of reads.
    /// - A loose file is read as it is.
    ///
    /// The returned sample carries its plan, which TaxTriage's provenance records.
    public static func resolve(
        _ sample: TaxTriageSample,
        materializationDirectory: URL,
        materializer: any CLISequenceInputMaterializing & Sendable,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> TaxTriageSample {
        var resolved = sample
        if let fastq2 = sample.fastq2 {
            resolved.fastq1 = try await mateFile(
                sample.fastq1,
                materializationDirectory: materializationDirectory,
                materializer: materializer,
                progress: progress
            )
            resolved.fastq2 = try await mateFile(
                fastq2,
                materializationDirectory: materializationDirectory,
                materializer: materializer,
                progress: progress
            )
            return resolved
        }
        guard SequenceInputResolver.enclosingFASTQBundleURL(for: sample.fastq1) != nil else { return sample }
        let readSet = try await SamplesheetReadSetPlanner.plan(
            input: sample.fastq1,
            consumerID: consumerID,
            materializationDirectory: materializationDirectory,
            materializer: materializer,
            progress: progress
        )
        switch readSet.reads {
        case .singleEnd(let file):
            resolved.fastq1 = file
            resolved.readLayout = readSet.plan.singleReadReason == nil ? .singleEnd : .mixedMergedAndPairs
        case .matePair(let r1, let r2):
            resolved.fastq1 = r1
            resolved.fastq2 = r2
            resolved.readLayout = .pairedFiles
        case .interleaved(let file):
            // The pipeline splits a strictly interleaved file into R1 and R2.
            resolved.fastq1 = file
            resolved.readLayout = .strictlyInterleaved
        }
        resolved.readSetPlan = readSet.plan
        if let reason = readSet.plan.singleReadReason {
            progress?("\(sample.sampleId): \(reason)")
        }
        return resolved
    }

    /// The one read file a sample's R1 or R2 input names. A file the user
    /// named is read as it is, and a `.lungfishfastq` bundle must hold exactly
    /// one file of reads (a virtual bundle is materialized to one).
    private static func mateFile(
        _ input: URL,
        materializationDirectory: URL,
        materializer: any CLISequenceInputMaterializing & Sendable,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        guard FASTQBundle.isBundleURL(input) else { return input }
        let readSet = try await SamplesheetReadSetPlanner.plan(
            input: input,
            consumerID: consumerID,
            materializationDirectory: materializationDirectory,
            materializer: materializer,
            progress: progress
        )
        guard case .singleEnd(let file) = readSet.reads, !readSet.changesTheRun else {
            throw SamplesheetReadSetPlannerError.notOneReadFile(
                path: input.path,
                detail: "it holds read pairs, a mix of read kinds or several files"
            )
        }
        return file
    }
}
