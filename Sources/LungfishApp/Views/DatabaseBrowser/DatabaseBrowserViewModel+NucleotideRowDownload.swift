// DatabaseBrowserViewModel+NucleotideRowDownload.swift - The NCBI browser's nucleotide and virus rows through lungfish-cli fetch ncbi --bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow
import os.log

extension DatabaseBrowserViewModel {
    /// The arguments of `fetch ncbi --bundle` for `accessions` into `folder`. They never hold the
    /// NCBI key, which reaches the child through its environment (SWIFT 6).
    nonisolated static func nucleotideFetchArguments(
        accessions: [String], folder: URL, includeGFF3Annotations: Bool
    ) -> [String] {
        ["fetch", "ncbi"] + accessions + ["--bundle", "--output-dir", folder.path]
            + (includeGFF3Annotations ? [] : ["--no-gff3"]) + ["--format", "json"]
    }

    /// Downloads the nucleotide or virus row `record`, row `index` of the `totalCount` rows of the
    /// batch row `operationID`, through `lungfish-cli fetch ncbi --bundle` into
    /// ``genomeRowFolder(projectURL:userDownloads:)``, and returns its bundle. `cliURLOverride`
    /// names the CLI a test launches.
    nonisolated static func downloadNucleotideRow(
        _ record: SearchResultRecord,
        index: Int,
        totalCount: Int,
        operationID: UUID,
        ncbi: NCBIService,
        includeGFF3Annotations: Bool,
        projectURL: URL?,
        cliURLOverride: URL? = nil
    ) async throws -> URL {
        let accession = record.accession.trimmingCharacters(in: .whitespacesAndNewlines)
        let download = GenomeRowCLIDownload(
            operationID: operationID, index: index, totalCount: totalCount, cliURLOverride: cliURLOverride)
        return try await download.run(
            nucleotideFetchArguments(
                accessions: [accession], folder: genomeRowFolder(projectURL: projectURL),
                includeGFF3Annotations: includeGFF3Annotations),
            apiKey: await ncbi.resolvedAPIKey
        )
    }
}
