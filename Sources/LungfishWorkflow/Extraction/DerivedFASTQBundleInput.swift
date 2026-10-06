// DerivedFASTQBundleInput.swift - Read the real reads of a derived FASTQ bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Resolves the files a tool should read for a sequence input, materializing
/// derived bundles whose reads exist only as a recipe over their root bundle.
///
/// `SequenceInputResolver.resolvePrimarySequenceURL` returns the root bundle's
/// original reads for such a bundle (oriented, subset, trimmed or
/// demultiplexed), and the bundle's own FASTQ is only a short preview. Reading
/// either silently processes the wrong reads. It also returns one file of a
/// bundle that holds several, chunk 0 of a chunked root or R1 of a paired
/// derivative, so reading it silently leaves reads out.
public enum DerivedFASTQBundleInput {
    /// Writes a derived bundle's reads to a file in `directory` and returns it.
    public typealias Materializer = @Sendable (_ bundleURL: URL, _ directory: URL) async throws -> URL

    /// The default materializer, shared by the app and `lungfish-cli`.
    public static let defaultMaterializer: Materializer = { bundleURL, directory in
        try await FASTQCLIMaterializer(runner: .shared).materialize(bundleURL: bundleURL, tempDirectory: directory)
    }

    /// The files a tool that reads every record on its own (MAFFT) reads for
    /// `inputURL`, in order, so it reads every read of the input once.
    ///
    /// A `.lungfishfastq` bundle, or a file inside one, is the files
    /// ``ReadSetResolver`` plans for single reads. Those are every chunk of a
    /// chunked root in import order, both mate files of a paired derivative,
    /// every role file of a mixed derivative, or a virtual derivative
    /// materialized into `directory` from its root. Any other input is the
    /// resolver's primary file. Before, a bundle gave the one-file
    /// resolution, which left out every file after chunk 0 or R1 (Phase 1
    /// note N1, Phase 2.1 lane L3).
    public static func readableURLs(
        for inputURL: URL,
        in directory: URL,
        materializer: @escaping Materializer = defaultMaterializer
    ) async throws -> [URL] {
        guard SequenceInputResolver.enclosingFASTQBundleURL(for: inputURL) != nil else {
            return SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL).map { [$0] } ?? []
        }
        let plan = try await ReadSetResolver(
            materializationDirectory: directory,
            materializer: ClosureMaterializer(materializer)
        ).plan(for: inputURL, capability: .singleReadsOnly)
        return plan.executionURLs
    }

    /// A ``Materializer`` closure in the form ``ReadSetResolver`` takes.
    public struct ClosureMaterializer: CLISequenceInputMaterializing, Sendable {
        public let write: Materializer

        public init(_ write: @escaping Materializer) {
            self.write = write
        }

        public func materialize(
            bundleURL: URL,
            tempDirectory: URL,
            progress: (@Sendable (String) -> Void)?
        ) async throws -> URL {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            return try await write(bundleURL, tempDirectory)
        }
    }
}
