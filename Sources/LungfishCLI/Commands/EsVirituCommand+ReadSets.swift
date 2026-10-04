// EsVirituCommand+ReadSets.swift - How lungfish-cli esviritu detect reads a bundle as pairs and single reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

extension EsVirituCommand.DetectSubcommand {

    /// Plans the sample's read set through ``EsVirituConfig/readSet(for:materializedInputs:materializationDirectory:progress:)``,
    /// the function the app's EsViritu launch runs too (owner decision 1 of
    /// 2026-10-03, docs/contracts/READ-PAIRING.md), and sets `config` from it.
    ///
    /// One bundle or file under `--read-format auto` runs its separate R1 and
    /// R2 files as a pair. A sample that mixes pairs and single reads, and a
    /// sample of several files of single reads, run `-p unpaired` on one file
    /// that holds every read. Any other input, and one of single reads only or
    /// one interleaved file, keeps today's config and returns false.
    func planReadSet(
        inputURLs: [URL],
        executionInputURLs: [URL],
        config: inout EsVirituConfig,
        materializationDirectory: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Bool {
        guard readFormat == .auto, !pairedEnd,
              let input = SamplesheetReadSetPlanner.plannableInput(inputURLs) else {
            return false
        }
        let readSet = try await EsVirituConfig.readSet(
            for: input,
            materializedInputs: executionInputURLs,
            materializationDirectory: materializationDirectory,
            progress: progress
        )
        return config.apply(readSet)
    }
}
