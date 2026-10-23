// FASTQIngestionPipeline+TrimGaloreSplit.swift - Trim Galore stores merged reads and read pairs as clumpify does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension FASTQIngestionPipeline {

    /// Runs Trim Galore's `--clumpify` mode for final-stage FASTQ storage optimization through the portable storage
    /// step (``PortableStorageStep/trimGalore(_:progress:)``), which runs the scan and split of an interleaved file,
    /// the per-half calls of a file that mixes pairs with unpaired reads, the `reformat.sh` interleave of Trim
    /// Galore's paired outputs, the join, the compressor and the read accounting from each call's trimming report.
    /// This Mac names the heap of Trim Galore's `--memory`, ``ClumpingTool/clumpifyHeapBytes(physicalMemoryBytes:)``
    /// of its own memory, and the compressor by what is installed.
    func trimGaloreClumpify(
        config: FASTQIngestionConfig,
        outputFile: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQProcessingRecord {
        typealias Step = PortableStorageStep<NativeToolStorageLauncher>
        let pairing: Step.TrimGalorePairing
        switch config.pairingMode {
        case .pairedEnd: pairing = .pairs
        case .interleaved where config.inputFiles.count == 1: pairing = .interleavedFile
        default: pairing = .single
        }
        let run = Step.TrimGaloreRun(
            inputs: config.inputFiles,
            pairing: pairing,
            output: outputFile,
            workingDirectory: config.outputDirectory,
            stem: Self.deriveBaseName(from: config.inputFiles[0]),
            threads: config.threads,
            compressionLevel: config.compressionLevel.zlValue,
            memoryBytes: ClumpingTool.clumpifyHeapBytes(
                physicalMemoryBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory)
            ),
            compressor: await resolveCompressor()
        )
        let step = storageStep
        let outcome = try await Self.mappingStorageErrors { try await step.trimGalore(run, progress: progress) }
        return FASTQProcessingRecord(
            url: outputFile,
            tool: "trim_galore",
            toolVersion: outcome.records[0].evidence.version,
            commandLine: outcome.records.map(Self.storageCommandLine).joined(separator: " && "),
            steps: outcome.records.map(\.step),
            readsRemovedByStorage: Self.storageReadRemoval(pairs: outcome.pairsReport, unpaired: outcome.unpairedReport)
        )
    }
}
