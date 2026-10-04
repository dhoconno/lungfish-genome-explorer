// TaxTriageCommand+ReadSets.swift - How lungfish-cli taxtriage run reads a bundle as pairs and single reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

extension TaxTriageCommand.RunSubcommand {

    /// The folder in the output directory that holds the files a virtual
    /// bundle is materialized into and the files a join writes. The command
    /// removes it when the run ends, as the app removes its scratch folder.
    static let materializationDirectoryName = ".lungfish-taxtriage-inputs"

    /// `samples` with each one's inputs resolved to the files TaxTriage reads,
    /// through ``TaxTriageReadSetPlanner/resolve(_:materializationDirectory:materializer:progress:)``,
    /// the function the app's TaxTriage launch runs too (owner decision 1 of
    /// 2026-10-03, docs/contracts/READ-PAIRING.md).
    ///
    /// A bundle of pairs gives `fastq_1` and `fastq_2`, a strictly interleaved
    /// file stays one file for the pipeline to split, and a bundle that mixes
    /// pairs and single reads, or holds several files of single reads, gives
    /// one single-end file that holds every read. A virtual bundle is
    /// materialized into `materializationDirectory` first. A loose file is
    /// read as it is.
    static func resolveSamples(
        _ samples: [TaxTriageSample],
        materializationDirectory: URL,
        materializer: any CLISequenceInputMaterializing & Sendable,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [TaxTriageSample] {
        var resolved: [TaxTriageSample] = []
        for sample in samples {
            resolved.append(try await TaxTriageReadSetPlanner.resolve(
                sample,
                materializationDirectory: materializationDirectory,
                materializer: materializer,
                progress: progress
            ))
        }
        return resolved
    }
}
