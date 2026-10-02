// FASTQDerivativeService+FastpTrim.swift - Fastp trim operations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {

    // MARK: - Fastp Trim Operations

    /// The fastp operation a derivative request asks for, or nil when the
    /// request is not a fastp trim. The window renders it through
    /// ``FastpTrimOptions`` exactly as `lungfish-cli fastq trim` and its
    /// siblings do, which the parity tests assert.
    static func fastpTrimOperation(
        for request: FASTQDerivativeRequest,
        sourceBundleURL: URL
    ) throws -> FastpTrimOperation? {
        switch request {
        case .fastpTrim(let threshold, let windowSize, let mode, let adapterMode, let adapterSequence):
            return .combined(
                threshold: threshold,
                window: windowSize,
                mode: mode,
                adapterTrimming: adapterMode != .fastaFile,
                adapterSequence: adapterMode == .specified ? adapterSequence : nil
            )
        case .qualityTrim(let threshold, let windowSize, let mode, _):
            return .quality(threshold: threshold, window: windowSize, mode: mode)
        case .adapterTrim(let adapterMode, let sequence, let sequenceR2, let fastaFilename):
            return try adapterTrimOperation(
                mode: adapterMode,
                sequence: sequence,
                sequenceR2: sequenceR2,
                fastaFilename: fastaFilename,
                sourceBundleURL: sourceBundleURL
            )
        case .fixedTrim(let from5Prime, let from3Prime):
            return .fixed(front: from5Prime, tail: from3Prime)
        default:
            return nil
        }
    }

    private static func adapterTrimOperation(
        mode: FASTQAdapterMode,
        sequence: String?,
        sequenceR2: String?,
        fastaFilename: String?,
        sourceBundleURL: URL
    ) throws -> FastpTrimOperation {
        switch mode {
        case .autoDetect:
            return .adapter(sequence: nil, sequenceR2: nil, adapterFastaPath: nil)
        case .specified:
            return .adapter(sequence: sequence, sequenceR2: sequenceR2, adapterFastaPath: nil)
        case .fastaFile:
            var fastaPath: String?
            if let fastaFilename,
               let fastaURL = try? FASTQBundle.validatedBundleMemberURL(
                for: fastaFilename,
                in: sourceBundleURL,
                field: "adapterTrim.fastaFilename"
               ) {
                fastaPath = fastaURL.path
            }
            return .adapter(sequence: nil, sequenceR2: nil, adapterFastaPath: fastaPath)
        }
    }

    func runFastpQualityTrim(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        threshold: Int,
        windowSize: Int,
        mode: FASTQQualityTrimMode,
        extraArguments: [String] = [],
        pairsByName: Bool = false,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws {
        try await runFastpTrim(
            .quality(threshold: threshold, window: windowSize, mode: mode),
            extraArguments: extraArguments,
            sourceFASTQ: sourceFASTQ,
            outputFASTQ: outputFASTQ,
            pairsByName: pairsByName,
            provenanceCollector: provenanceCollector
        )
    }

    func runFastpCombinedTrim(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        threshold: Int,
        windowSize: Int,
        mode: FASTQQualityTrimMode,
        adapterMode: FASTQAdapterMode,
        adapterSequence: String?,
        pairsByName: Bool = false,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws {
        try await runFastpTrim(
            .combined(
                threshold: threshold,
                window: windowSize,
                mode: mode,
                adapterTrimming: adapterMode != .fastaFile,
                adapterSequence: adapterMode == .specified ? adapterSequence : nil
            ),
            sourceFASTQ: sourceFASTQ,
            outputFASTQ: outputFASTQ,
            pairsByName: pairsByName,
            provenanceCollector: provenanceCollector
        )
    }

    func runFastpAdapterTrim(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        mode: FASTQAdapterMode,
        sequence: String?,
        sequenceR2: String?,
        fastaFilename: String?,
        sourceBundleURL: URL,
        pairsByName: Bool = false,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws {
        try await runFastpTrim(
            try Self.adapterTrimOperation(
                mode: mode,
                sequence: sequence,
                sequenceR2: sequenceR2,
                fastaFilename: fastaFilename,
                sourceBundleURL: sourceBundleURL
            ),
            sourceFASTQ: sourceFASTQ,
            outputFASTQ: outputFASTQ,
            pairsByName: pairsByName,
            provenanceCollector: provenanceCollector
        )
    }

    func runFastpFixedTrim(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        from5Prime: Int,
        from3Prime: Int,
        pairsByName: Bool = false,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws {
        try await runFastpTrim(
            .fixed(front: from5Prime, tail: from3Prime),
            sourceFASTQ: sourceFASTQ,
            outputFASTQ: outputFASTQ,
            pairsByName: pairsByName,
            provenanceCollector: provenanceCollector
        )
    }

    /// Runs one fastp trim through ``FastpPairedRunner``, the implementation
    /// behind `lungfish-cli fastq trim` and its siblings, so the window and
    /// the CLI keep the same reads: paired input is partitioned by name and
    /// fastp runs in its paired mode (both mates kept or dropped together,
    /// read 2 adapters detected), the unpaired reads of a mixed file run
    /// single-end, and the output is interleaved again. The old
    /// `--interleaved_in` run kept 90,622 reads on the HG002 fixture where
    /// the CLI kept 90,556.
    ///
    /// - Parameter pairsByName: `true` when adjacent records may be mates
    ///   (a strictly interleaved or mixed input); every record of the file
    ///   is then scanned by name before fastp runs.
    private func runFastpTrim(
        _ operation: FastpTrimOperation,
        extraArguments: [String] = [],
        sourceFASTQ: URL,
        outputFASTQ: URL,
        pairsByName: Bool,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector?
    ) async throws {
        let plan = try await Task.detached(priority: .utility) {
            try FastpReadLayoutPlan.resolve(inputURL: sourceFASTQ, pairAware: pairsByName)
        }.value
        let options = FastpTrimOptions.options(for: operation, extraArguments: extraArguments)
        do {
            _ = try await FastpPairedRunner.run(
                inputURL: sourceFASTQ,
                outputPath: outputFASTQ.path,
                plan: plan,
                options: options,
                detectPairedAdapters: operation.detectsPairedAdapters,
                failureLabel: operation.failureLabel,
                stepNamePrefix: "lungfish fastq \(operation.subcommandName)",
                runner: runner,
                execute: { tool, arguments in
                    try await self.runNativeTool(tool, arguments: arguments, provenanceCollector: provenanceCollector)
                }
            )
        } catch let error as FastpPairedRunError {
            throw FASTQDerivativeError.invalidOperation(error.message)
        }
    }

    /// Re-interleaves split R1/R2 fastp output back into a single interleaved file
    /// using reformat.sh, then cleans up the temp files.
    func reinterleaveFastpOutput(
        r1: URL,
        r2: URL,
        output: URL,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws {
        let env = await bbToolsEnvironment()
        let result = try await runNativeTool(
            .reformat,
            arguments: [
                "in1=\(r1.path)",
                "in2=\(r2.path)",
                "out=\(output.path)",
                "interleaved=t",
            ],
            environment: env,
            timeout: 1800,
            provenanceCollector: provenanceCollector
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("reformat.sh re-interleave failed: \(result.stderr)")
        }
        try? FileManager.default.removeItem(at: r1)
        try? FileManager.default.removeItem(at: r2)
    }

    /// Splits an interleaved FASTQ into separate R1/R2 files using reformat.sh.
    func deinterleaveFASTQ(
        source: URL,
        outputR1: URL,
        outputR2: URL,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws {
        let env = await bbToolsEnvironment()
        let result = try await runNativeTool(
            .reformat,
            arguments: [
                "in=\(source.path)",
                "out1=\(outputR1.path)",
                "out2=\(outputR2.path)",
                "interleaved=t",
            ],
            environment: env,
            timeout: 1800,
            provenanceCollector: provenanceCollector
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("reformat.sh deinterleave failed: \(result.stderr)")
        }
    }

}
