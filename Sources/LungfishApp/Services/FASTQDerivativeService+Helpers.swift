// FASTQDerivativeService+Helpers.swift - Helpers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {

    // MARK: - Helpers

    /// Extracts read IDs from a FASTQ file using `seqkit seq --name --only-id`.
    ///
    /// For PE interleaved data, deduplicates the ID list so that re-extraction
    /// with `seqkit grep -f` naturally includes both mates (R1 and R2) for each
    /// base ID. Returns the number of unique IDs written.
    func writeReadIDs(fromFASTQ fastqURL: URL, to outputURL: URL, deduplicate: Bool = false) async throws -> Int {
        let rawOutputURL: URL
        if deduplicate {
            rawOutputURL = outputURL.deletingLastPathComponent().appendingPathComponent("raw-ids.txt")
        } else {
            rawOutputURL = outputURL
        }

        let result = try await runner.runWithFileOutput(
            .seqkit,
            arguments: [
                "seq", "--name", "--only-id",
                fastqURL.path,
            ],
            outputFile: rawOutputURL,
            timeout: 600
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("seqkit seq --name failed: \(result.stderr)")
        }

        if deduplicate {
            try deduplicateIDFile(from: rawOutputURL, to: outputURL)
            try? FileManager.default.removeItem(at: rawOutputURL)
        }

        // Count lines in the output to get read count
        let content = try String(contentsOf: outputURL, encoding: .utf8)
        return content.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    func createOutputBundleURL(
        sourceBundleURL: URL,
        operation: FASTQDerivativeOperation
    ) throws -> URL {
        let derivDir = try FASTQBundle.ensureDerivativesDirectory(in: sourceBundleURL)
        let shortID = UUID().uuidString.prefix(8).lowercased()
        let base = "\(operation.shortLabel)-\(shortID)"

        var candidate = derivDir.appendingPathComponent("\(base).\(FASTQBundle.directoryExtension)", isDirectory: true)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = derivDir.appendingPathComponent("\(base)-\(suffix).\(FASTQBundle.directoryExtension)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    func makeTemporaryDirectory(prefix: String, contextURL: URL? = nil) throws -> URL {
        if let contextURL {
            return try ProjectTempDirectory.createFromContext(prefix: prefix, contextURL: contextURL)
        }
        return try ProjectTempDirectory.create(prefix: prefix, in: nil)
    }

    func uniqueDirectoryURL(startingAt initialURL: URL) -> URL {
        var candidate = initialURL
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = initialURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(initialURL.lastPathComponent)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    func relativePath(from baseURL: URL, to targetURL: URL) -> String {
        let baseComponents = baseURL.standardizedFileURL.pathComponents
        let targetComponents = targetURL.standardizedFileURL.pathComponents

        var common = 0
        while common < min(baseComponents.count, targetComponents.count),
              baseComponents[common] == targetComponents[common] {
            common += 1
        }

        let up = Array(repeating: "..", count: max(0, baseComponents.count - common))
        let down = Array(targetComponents.dropFirst(common))
        let parts = up + down
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    /// Computes a filesystem-relative path from one bundle to another.
    ///
    /// Used as a fallback when no `.lungfish` project root exists (e.g. in tests).
    func relativePathFromBundle(_ fromBundle: URL, to targetBundle: URL) -> String {
        relativePath(from: fromBundle, to: targetBundle)
    }

    func isInterleavedBundle(_ bundleURL: URL) -> Bool {
        if let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) {
            return manifest.pairingMode == .interleaved
        }
        if let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) {
            return FASTQMetadataStore.load(for: fastqURL)?.ingestion?.pairingMode == .interleaved
        }
        return false
    }

    func normalizedIdentifier(_ identifier: String) -> String {
        var value = identifier
        if let space = value.firstIndex(of: " ") {
            value = String(value[..<space])
        }
        return value
    }

}
