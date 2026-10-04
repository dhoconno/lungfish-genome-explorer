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
    /// - A `.lungfishfastq` bundle path (`fastq2` nil) is the whole bundle,
    ///   planned by ``SamplesheetReadSetPlanner``. A sample of pairs only
    ///   gives `fastq_1` and `fastq_2`, a strictly interleaved file stays one
    ///   file for the pipeline to split, and a sample that mixes pairs and
    ///   single reads, or holds several files of single reads, gives one
    ///   single-end file that holds every read. A virtual bundle is
    ///   materialized first.
    /// - A file the user names is that file, a chunk or a mate included, as
    ///   `taxtriage run --input <file>` always read it. The one exception is
    ///   the preview of a virtual bundle, which holds a few reads of the sample
    ///   and not the sample, so it names its bundle.
    /// - Two inputs that are every member file of one bundle collapse to that
    ///   bundle and are planned as the bundle is (``SamplesheetReadSetPlanner/bundleNamedByEveryMemberFile(_:)``).
    ///   Two chunks of one run are then one joined file, never `fastq_1` and
    ///   `fastq_2`.
    /// - Any other sample that names two inputs as R1 and R2 reads each as one
    ///   file, and refuses a bundle that is not one file of reads.
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
            if let bundleURL = await SamplesheetReadSetPlanner.bundleNamedByEveryMemberFile([sample.fastq1, fastq2]) {
                var named = sample
                named.fastq1 = bundleURL
                named.fastq2 = nil
                return try await resolve(
                    named,
                    materializationDirectory: materializationDirectory,
                    materializer: materializer,
                    progress: progress
                )
            }
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
        guard let bundleURL = bundleToPlan(for: sample.fastq1, progress: progress) else { return sample }
        let readSet = try await SamplesheetReadSetPlanner.plan(
            input: bundleURL,
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

    /// The bundle to plan for one named input, or nil when the input is read as
    /// it is. A bundle path is the whole bundle. A file the user names is that
    /// file, a chunk included, as the `fastq` subcommands read a file inside a
    /// bundle in place. The only exception is the preview of a virtual bundle,
    /// which names its bundle, with the note those subcommands print, because a
    /// classifier never runs on a preview of the reads.
    private static func bundleToPlan(for input: URL, progress: (@Sendable (String) -> Void)?) -> URL? {
        if FASTQBundle.isBundleURL(input) { return input }
        guard FASTQBundle.isFASTQFileURL(input),
              let bundleURL = SequenceInputResolver.unmaterializedDerivedBundleURL(for: input) else {
            return nil
        }
        progress?("\(input.lastPathComponent) is the preview of the virtual bundle \(bundleURL.lastPathComponent), not its reads. Reading the bundle instead.")
        return bundleURL
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
        guard let bundleURL = bundleToPlan(for: input, progress: progress) else { return input }
        let readSet = try await SamplesheetReadSetPlanner.plan(
            input: bundleURL,
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
