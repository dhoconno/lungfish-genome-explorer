// FASTQDerivativeService+Core.swift - Export of a derived bundle to a FASTQ file
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {
    /// Materializes a derived FASTQ bundle to a standalone FASTQ file.
    ///
    /// Reads from the root FASTQ, applies the derivative's filter or trim positions,
    /// and writes the result to the specified output URL.
    public func exportMaterializedFASTQ(
        fromDerivedBundle bundleURL: URL,
        to outputURL: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        guard FASTQBundle.isDerivedBundle(bundleURL) else {
            throw FASTQDerivativeError.derivedManifestMissing
        }

        let tempDir = try makeTemporaryDirectory(prefix: "fastq-export-", contextURL: bundleURL)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        progress?("Materializing dataset...")
        let materializedURL = try await materializeDatasetFASTQ(
            fromBundle: bundleURL,
            tempDirectory: tempDir,
            progress: progress
        )

        progress?("Writing to output file...")
        try FileManager.default.copyItem(at: materializedURL, to: outputURL)
        progress?("Export complete: \(outputURL.lastPathComponent)")
    }
}
