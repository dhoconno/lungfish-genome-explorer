// GenomeDownloadViewModel.swift - Genome assembly download and bundle building
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: NCBI Integration Lead (Role 12)

import Foundation
import LungfishCore
import LungfishWorkflow

// MARK: - GenomeDownloadViewModel

/// Downloads NCBI genome assemblies into `.lungfishref` bundles for the database browser and the
/// variant-only reference download. ``GenomeDownloadBundleBuilder`` builds each bundle.
public final class GenomeDownloadViewModel: Sendable {

    private let builder: GenomeDownloadBundleBuilder

    public init(
        ncbiService: NCBIService = NCBIService(),
        toolRunner: NativeToolRunner = .shared
    ) {
        self.builder = GenomeDownloadBundleBuilder(ncbiService: ncbiService, toolRunner: toolRunner)
    }

    /// Validates that required native tools are available.
    public func validateTools() async throws {
        try await builder.validateTools()
    }

    /// Downloads FASTA and GFF3 files for an assembly and builds a `.lungfishref` bundle.
    public func downloadAndBuild(
        assembly: NCBIAssemblySummary,
        outputDirectory: URL,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        try await builder.downloadAndBuild(
            assembly: assembly, outputDirectory: outputDirectory, progressHandler: progressHandler)
    }
}
