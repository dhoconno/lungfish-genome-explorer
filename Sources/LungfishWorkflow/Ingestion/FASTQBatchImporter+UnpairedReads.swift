// FASTQBatchImporter+UnpairedReads.swift - A run's reads without a mate import beside its pairs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// ENA's mirror and the SRA Toolkit name a run's files `<run>_1`, `<run>_2`
/// and `<run>`, and the third file holds the spots whose mate is missing.
/// `import fastq` imports the three as one sample, the pairs as pairs and
/// the third file's reads as unpaired reads, in the one-file mixed form a
/// merge recipe writes (row L3 of docs/contracts/READ-PAIRING.md). The
/// window imports an SRA run through this command, so both keep every read.
extension FASTQBatchImporter {

    // MARK: - Detection

    /// Joins each run's file of reads without a mate to the pair detected
    /// from `<run>_1` and `<run>_2`.
    ///
    /// That file used to import as a second sample of the same name, which
    /// found the pair's bundle and was skipped, so the bundle held part of
    /// the run. A bare file beside an `_R1` and `_R2` pair, a BAM, and a name
    /// two bare files share keep their own samples.
    static func joiningUnpairedReads(_ samples: [SamplePair]) -> [SamplePair] {
        let singles = Dictionary(
            grouping: samples.filter { $0.r2 == nil && !SequencingReadImportSource.isBAM($0.r1) },
            by: \.sampleName
        )
        var joinedFiles: Set<URL> = []
        let joined = samples.map { sample -> SamplePair in
            guard let r2 = sample.r2, sample.unpaired == nil,
                  !SequencingReadImportSource.isBAM(sample.r1),
                  fastqStem(sample.r1) == "\(sample.sampleName)_1",
                  fastqStem(r2) == "\(sample.sampleName)_2",
                  let matches = singles[sample.sampleName], matches.count == 1 else {
                return sample
            }
            joinedFiles.insert(matches[0].r1)
            return SamplePair(
                sampleName: sample.sampleName,
                r1: sample.r1,
                r2: r2,
                unpaired: matches[0].r1,
                relativePath: sample.relativePath,
                metadata: sample.metadata,
                sampleSheetURL: sample.sampleSheetURL
            )
        }
        return joined.filter { $0.r2 != nil || !joinedFiles.contains($0.r1) }
    }

    // MARK: - Import

    /// The one file a sample's pairs and its reads without a mate import as.
    struct UnpairedReadsLayout {
        /// Each R1 record followed by its R2 record, then every read without
        /// a mate, as plain FASTQ in the import workspace.
        let file: URL
        /// The pairs and the reads without a mate that the file holds.
        let counts: RecipeMixedLayoutCounts
        /// The provenance step that wrote the file, with its record counts.
        let step: StepExecution
        /// The reads each input file held, by file name.
        let inputReadCounts: [String: ParameterValue]
    }

    /// Writes a sample's pairs, mate names checked record by record, and
    /// then its reads without a mate into one file in `workspace`. Returns
    /// nil for a sample with no file of unpaired reads.
    ///
    /// This is the read-set resolver's interleave by name, so the ingestion
    /// pipeline stores the file as it stores a merge recipe's mixed output,
    /// and the sidecar records how many reads of each kind it holds.
    static func writePairsThenUnpairedReads(
        of pair: SamplePair,
        in workspace: URL,
        log: (@Sendable (ImportLogEvent) -> Void)?
    ) async throws -> UnpairedReadsLayout? {
        guard let r2 = pair.r2, let unpaired = pair.unpaired else { return nil }
        let r1 = pair.r1
        let output = workspace.appendingPathComponent("\(pair.sampleName)_pairs_then_unpaired.fastq")
        let startedAt = Date()
        let counts = try await Task.detached(priority: .utility) {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let pairs = try FASTQPairInterleaver.interleave(r1: r1, r2: r2, to: handle, requireMates: true)
            let singles = try FASTQPairInterleaver.writeMergedThenPairs(
                merged: unpaired,
                unmergedR1: nil,
                unmergedR2: nil,
                to: handle
            )
            return RecipeMixedLayoutCounts(mergedReads: 0, pairs: pairs.r1Records, unpairedReads: singles.mergedRecords)
        }.value
        let step = try ReadSetStep(
            kind: .interleaveByName,
            inputURLs: [r1, r2, unpaired],
            outputURLs: [output],
            pairCount: counts.pairs,
            singleReadCount: counts.unpairedReads,
            startedAt: startedAt,
            endedAt: Date()
        ).stepExecution(toolVersion: WorkflowRun.currentAppVersion)
        log?(.notice(
            sample: pair.sampleName,
            message: "\(unpaired.lastPathComponent) holds \(counts.unpairedReads) reads whose mate is missing. "
                + "They import as unpaired reads beside the \(counts.pairs) pairs."
        ))
        return UnpairedReadsLayout(
            file: output,
            counts: counts,
            step: step,
            inputReadCounts: [
                r1.lastPathComponent: .integer(counts.pairs),
                r2.lastPathComponent: .integer(counts.pairs),
                unpaired.lastPathComponent: .integer(counts.unpairedReads),
            ]
        )
    }

    /// A recipe reads pairs or single reads, not both, so a sample that also
    /// holds reads without a mate cannot run one without leaving reads out.
    /// The import refuses it and names the file.
    static func validateRecipeKeepsUnpairedReads(pair: SamplePair, config: ImportConfig) throws {
        guard let unpaired = pair.unpaired,
              let recipe = config.newRecipe?.name ?? config.recipe.flatMap({ $0.steps.isEmpty ? nil : $0.name })
        else { return }
        throw BatchImportError.recipeNotApplicable(
            recipe: recipe,
            sample: pair.sampleName,
            reason: "\(unpaired.lastPathComponent) holds reads whose mate is missing, and a recipe reads only "
                + "pairs or only single reads. Import the run with no recipe to keep every read."
        )
    }

    // MARK: - Provenance

    /// The explicit option a sample with reads without a mate records. Any
    /// other sample records none, so its record reads as it did.
    static func unpairedReadsParameters(of pair: SamplePair) -> [String: ParameterValue] {
        pair.unpaired.map { ["unpaired": .file($0)] } ?? [:]
    }
}
