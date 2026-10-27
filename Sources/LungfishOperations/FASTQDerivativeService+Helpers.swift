// FASTQDerivativeService+Helpers.swift - Helpers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log
import LungfishPortable

extension FASTQDerivativeService {
    // MARK: - Helpers

    func makeTemporaryDirectory(prefix: String, contextURL: URL? = nil) throws -> URL {
        if let contextURL {
            return try ProjectTempDirectory.createFromContext(prefix: prefix, contextURL: contextURL)
        }
        return try ProjectTempDirectory.create(prefix: prefix, in: nil)
    }

    /// Whether the bundle's reads are strictly interleaved pairs, by the same
    /// resolver every FASTQ consumer uses (metadata, then a record scan).
    nonisolated func isInterleavedBundle(_ bundleURL: URL) -> Bool {
        FASTQInputLayoutResolver.resolve(inputURLs: [bundleURL]).layout == .strictlyInterleaved
    }

    func normalizedIdentifier(_ identifier: String) -> String {
        var value = identifier
        if let space = value.firstIndex(of: " ") {
            value = String(value[..<space])
        }
        return value
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
            arguments: BBToolsPairArguments.interleave(r1: r1.path, r2: r2.path, output: output.path),
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
            arguments: BBToolsPairArguments.deinterleave(input: source.path, out1: outputR1.path, out2: outputR2.path),
            environment: env,
            timeout: 1800,
            provenanceCollector: provenanceCollector
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("reformat.sh deinterleave failed: \(result.stderr)")
        }
    }
}
