// TaxTriagePipeline+ReadLayout.swift - Run strictly interleaved single-file samples as R1/R2 pairs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// LGE stores a paired import as ONE interleaved FASTQ inside a
// `.lungfishfastq` bundle. TaxTriage reads pairs only through the samplesheet's
// fastq_1/fastq_2 columns, so a single interleaved file used to run as
// single-end reads. The repo's mixed-read contract (FASTQInputLayout.swift) is
// to hand pairs to a tool that can take them: a strictly interleaved file is
// split into two temporary mate files with the same split Kraken 2 uses
// (ClassificationPipeline.splitInterleavedInput), and both go in the
// samplesheet. A file that mixes merged reads with pairs still runs as single
// reads, because a positional split would mis-pair it.

import Foundation
import LungfishIO

extension TaxTriagePipeline {

    /// One sample whose interleaved file was split into R1/R2 mate files.
    struct InterleavedSampleSplit: Sendable, Equatable {
        let sampleId: String
        /// The durable interleaved file the user chose.
        let source: URL
        let r1: URL
        let r2: URL
        let pairCount: Int
        let wallTime: TimeInterval
    }

    /// A config whose strictly interleaved samples now point at split mate files.
    struct ReadLayoutPreparedConfig: Sendable {
        let config: TaxTriageConfig
        let splits: [InterleavedSampleSplit]
    }

    /// Scratch directory (inside the run's output directory) that holds the
    /// mate files split from interleaved inputs. Removed when the run ends.
    static let interleavedSplitDirectoryName = ".lungfish-interleaved-split"

    /// The read layout TaxTriage should see for one sample.
    ///
    /// Two files are R1/R2. A layout the caller resolved before
    /// materialization (with the bundle's metadata as hints) is final;
    /// otherwise the shared resolver scans the file.
    static func resolvedReadLayout(for sample: TaxTriageSample) -> FASTQInputLayout {
        if sample.fastq2 != nil {
            return .pairedFiles
        }
        if let readLayout = sample.readLayout {
            return readLayout
        }
        return FASTQInputLayoutResolver.resolve(inputURLs: [sample.fastq1]).layout
    }

    /// Whether a sample is a single strictly interleaved Illumina file that
    /// should be split into R1/R2 before TaxTriage runs.
    ///
    /// Long-read platforms never carry mates, and TaxTriage's Oxford and
    /// PacBio paths read one file per sample.
    static func shouldSplitInterleaved(_ sample: TaxTriageSample) -> Bool {
        guard sample.fastq2 == nil, sample.platform == .illumina else { return false }
        return resolvedReadLayout(for: sample) == .strictlyInterleaved
    }

    /// Splits every strictly interleaved single-file sample of `config` into
    /// R1/R2 files under `splitRoot` and returns a config that points at the
    /// halves. Samples that are already R1/R2, single-end, or mixed are left
    /// alone. `splitRoot` is replaced if it exists; the caller removes it once
    /// the run no longer needs the halves.
    static func splitStrictlyInterleavedSamples(
        in config: TaxTriageConfig,
        splitRoot: URL,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ReadLayoutPreparedConfig {
        var prepared = config
        var splits: [InterleavedSampleSplit] = []
        var usedNames = Set<String>()

        for (index, sample) in config.samples.enumerated() where shouldSplitInterleaved(sample) {
            try Task.checkCancellation()
            progress?(0.05, "Splitting interleaved pairs of \(sample.sampleId) into R1/R2 for TaxTriage...")
            let directoryName = TaxTriageSerialBatchRunner.uniqueDirectoryName(
                for: sample.sampleId,
                usedNames: &usedNames
            )
            let directory = splitRoot.appendingPathComponent(directoryName, isDirectory: true)
            let start = Date()
            let split: (r1: URL, r2: URL, counts: FASTQPairInterleaver.Counts)
            do {
                split = try await ClassificationPipeline.splitInterleavedInput(sample.fastq1, into: directory)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw TaxTriagePipelineError.interleavedSplitFailed(
                    sampleId: sample.sampleId,
                    reason: error.localizedDescription
                )
            }
            prepared.samples[index].fastq1 = split.r1
            prepared.samples[index].fastq2 = split.r2
            prepared.samples[index].readLayout = .pairedFiles
            splits.append(InterleavedSampleSplit(
                sampleId: sample.sampleId,
                source: sample.fastq1,
                r1: split.r1,
                r2: split.r2,
                pairCount: split.counts.r1Records,
                wallTime: Date().timeIntervalSince(start)
            ))
        }

        return ReadLayoutPreparedConfig(config: prepared, splits: splits)
    }

    /// The samplesheet rows for a config: fastq_2 is filled whenever a sample
    /// has a second file (R1/R2 input or split interleaved pairs).
    static func samplesheetEntries(for config: TaxTriageConfig) -> [TaxTriageSampleEntry] {
        config.samples.map { sample in
            TaxTriageSampleEntry(
                sampleId: sample.sampleId,
                fastq1Path: sample.fastq1.path,
                fastq2Path: sample.fastq2?.path,
                platform: sample.platform.rawValue
            )
        }
    }
}
