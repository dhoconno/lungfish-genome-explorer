// GenBankBundleDownloadViewModel.swift - NCBI GenBank download and bundle building
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

/// Builds NCBI GenBank nucleotide downloads into `.lungfishref` bundles for the database browser
/// and the variant-only reference download. ``GenBankDownloadBundleBuilder`` builds each bundle.
public final class GenBankBundleDownloadViewModel: Sendable {

    private let builder: GenBankDownloadBundleBuilder

    public init(
        ncbiService: NCBIService = NCBIService(),
        toolRunner: NativeToolRunner = .shared
    ) {
        self.builder = GenBankDownloadBundleBuilder(ncbiService: ncbiService, toolRunner: toolRunner)
    }

    /// Throws `BundleBuildError.missingTools` when bgzip or samtools is missing.
    public func validateTools() async throws {
        try await builder.validateTools()
    }

    /// Downloads a GenBank record and builds a `.lungfishref` bundle from it.
    public func downloadAndBuild(
        accession: String,
        outputDirectory: URL,
        includeGFF3Annotations: Bool = true,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        try await builder.downloadAndBuild(
            accession: accession, outputDirectory: outputDirectory,
            includeGFF3Annotations: includeGFF3Annotations, progressHandler: progressHandler)
    }

    /// Builds a `.lungfishref` bundle from a sequence that no GenBank accession resolves.
    public func buildBundleFromSequence(
        accession: String,
        title: String?,
        sequence: String,
        outputDirectory: URL,
        sourceDatabase: String = "Pathoplexus",
        sourceURL: URL? = nil,
        notes: String? = nil,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        try await builder.buildBundleFromSequence(
            accession: accession, title: title, sequence: sequence, outputDirectory: outputDirectory,
            sourceDatabase: sourceDatabase, sourceURL: sourceURL, notes: notes, progressHandler: progressHandler)
    }
}
