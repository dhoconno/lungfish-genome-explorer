// FASTQDerivativeService+HumanScrub.swift - Human read scrub
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {

    // MARK: - Human Read Scrub

    /// Runs Deacon host depletion on a (possibly interleaved) FASTQ file.
    ///
    /// Deacon filters paired-end data from separate R1/R2 files, so interleaved
    /// inputs are split before filtering and re-interleaved after filtering.
    func runDeaconHumanReadScrub(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        databaseID: String,
        isInterleaved: Bool,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws {
        let dbPath = try await humanScrubberDatabasePath(databaseID)
        let threads = ProcessInfo.processInfo.activeProcessorCount

        let inputFASTQ: URL
        var decompressedTmp: URL? = nil
        if sourceFASTQ.pathExtension.lowercased() == "gz" {
            let tmp = outputFASTQ.deletingLastPathComponent()
                .appendingPathComponent("deacon_scrub_input_\(UUID().uuidString).fastq")
            let pigzResult = try await runner.runWithFileOutput(
                .pigz,
                arguments: ["-d", "-c", sourceFASTQ.path],
                outputFile: tmp
            )
            guard pigzResult.isSuccess else {
                throw FASTQDerivativeError.invalidOperation("Failed to decompress input for Deacon scrub: \(pigzResult.stderr)")
            }
            inputFASTQ = tmp
            decompressedTmp = tmp
        } else {
            inputFASTQ = sourceFASTQ
        }
        defer { if let tmp = decompressedTmp { try? FileManager.default.removeItem(at: tmp) } }

        if isInterleaved {
            let inputR1 = outputFASTQ.deletingLastPathComponent()
                .appendingPathComponent("deacon_scrub_input_\(UUID().uuidString)_R1.fastq")
            let inputR2 = outputFASTQ.deletingLastPathComponent()
                .appendingPathComponent("deacon_scrub_input_\(UUID().uuidString)_R2.fastq")
            let outputR1 = outputFASTQ.deletingLastPathComponent()
                .appendingPathComponent("deacon_scrub_output_\(UUID().uuidString)_R1.fastq")
            let outputR2 = outputFASTQ.deletingLastPathComponent()
                .appendingPathComponent("deacon_scrub_output_\(UUID().uuidString)_R2.fastq")
            defer {
                try? FileManager.default.removeItem(at: inputR1)
                try? FileManager.default.removeItem(at: inputR2)
                try? FileManager.default.removeItem(at: outputR1)
                try? FileManager.default.removeItem(at: outputR2)
            }

            try await deinterleaveFASTQ(
                source: inputFASTQ,
                outputR1: inputR1,
                outputR2: inputR2,
                provenanceCollector: provenanceCollector
            )

            let deaconResult = try await runNativeTool(
                .deacon,
                arguments: [
                    "filter",
                    "-d", dbPath.path,
                    inputR1.path,
                    inputR2.path,
                    "-o", outputR1.path,
                    "-O", outputR2.path,
                    "-t", "\(threads)",
                ],
                timeout: 7200,
                provenanceCollector: provenanceCollector
            )
            guard deaconResult.isSuccess else {
                throw FASTQDerivativeError.invalidOperation("deacon filter failed: \(deaconResult.stderr)")
            }

            try await reinterleaveFastpOutput(
                r1: outputR1,
                r2: outputR2,
                output: outputFASTQ,
                provenanceCollector: provenanceCollector
            )
        } else {
            let deaconResult = try await runNativeTool(
                .deacon,
                arguments: [
                    "filter",
                    "-d", dbPath.path,
                    inputFASTQ.path,
                    "-o", outputFASTQ.path,
                    "-t", "\(threads)",
                ],
                timeout: 7200,
                provenanceCollector: provenanceCollector
            )
            guard deaconResult.isSuccess else {
                throw FASTQDerivativeError.invalidOperation("deacon filter failed: \(deaconResult.stderr)")
            }
        }
    }

    func humanScrubberDatabasePath(_ databaseID: String) async throws -> URL {
        try await Self.resolveHumanScrubberDatabasePath(
            databaseID: databaseID,
            registry: databaseRegistry
        )
    }

}
