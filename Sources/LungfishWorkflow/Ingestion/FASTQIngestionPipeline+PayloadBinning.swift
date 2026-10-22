// FASTQIngestionPipeline+PayloadBinning.swift - Quality binning of one stored FASTQ file
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension FASTQIngestionPipeline {
    /// Bins the quality scores of one single-end FASTQ file into `outputFile`, keeping every read, its whole name,
    /// its sequence and its order.
    ///
    /// The pass is the pipeline's own `reformat.sh` launch with the `quantize=` argument clumpify takes for the
    /// scheme, so a stored ONT chunk and a clumpified Illumina import bin one score to the same value (lane
    /// C2-ONTBIN). The output is gzip when its name ends in `.gz` and plain text otherwise. The returned step names
    /// the tool, its version evidence and its argv.
    public func binQualities(
        of inputFile: URL,
        into outputFile: URL,
        scheme: QualityBinningScheme,
        threads: Int,
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> StepExecution {
        precondition(scheme != .none, "binQualities needs a binning scheme")
        let record = try await reformatQuantize(
            config: FASTQIngestionConfig(
                inputFiles: [inputFile],
                pairingMode: .singleEnd,
                outputDirectory: outputFile.deletingLastPathComponent(),
                threads: max(1, threads),
                deleteOriginals: false,
                qualityBinning: scheme,
                skipClumpify: true
            ),
            outputFile: outputFile,
            progress: progress
        )
        guard let step = record.steps.first else {
            throw FASTQIngestionError.qualityBinningFailed("reformat.sh recorded no step for \(inputFile.lastPathComponent)")
        }
        return step
    }
}
