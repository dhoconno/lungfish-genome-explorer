// DerivedFASTQBundleInput.swift - Read the real reads of a derived FASTQ bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Resolves the file a tool should read for a sequence input, materializing
/// derived bundles whose reads exist only as a recipe over their root bundle.
///
/// `SequenceInputResolver.resolvePrimarySequenceURL` returns the root bundle's
/// original reads for such a bundle (oriented, subset, trimmed or
/// demultiplexed), and the bundle's own FASTQ is only a short preview. Reading
/// either silently processes the wrong reads.
public enum DerivedFASTQBundleInput {
    /// Writes a derived bundle's reads to a file in `directory` and returns it.
    public typealias Materializer = @Sendable (_ bundleURL: URL, _ directory: URL) async throws -> URL

    /// The default materializer, shared by the app and `lungfish-cli`.
    public static let defaultMaterializer: Materializer = { bundleURL, directory in
        try await FASTQCLIMaterializer(runner: .shared).materialize(bundleURL: bundleURL, tempDirectory: directory)
    }

    /// The file to read for `inputURL`: a materialized copy in `directory` for
    /// an unmaterialized derived bundle, otherwise the resolver's primary file.
    public static func readableURL(
        for inputURL: URL,
        in directory: URL,
        materializer: Materializer = defaultMaterializer
    ) async throws -> URL? {
        if let bundleURL = SequenceInputResolver.unmaterializedDerivedBundleURL(for: inputURL) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try await materializer(bundleURL, directory)
        }
        return SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL)
    }
}
