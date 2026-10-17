// DatabaseBrowserViewModel+PathoplexusRowDownload.swift - The Pathoplexus browser's rows through lungfish-cli fetch pathoplexus
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow

extension DatabaseBrowserViewModel {
    /// The arguments of `fetch pathoplexus` for `accessions` of `organism` into `folder`. They never
    /// hold the NCBI key, which reaches the child through its environment (SWIFT 6).
    nonisolated static func pathoplexusFetchArguments(
        accessions: [String], organism: String, folder: URL, includeGFF3Annotations: Bool
    ) -> [String] {
        ["fetch", "pathoplexus"] + accessions + ["--organism", organism, "--output-dir", folder.path]
            + (includeGFF3Annotations ? [] : ["--no-gff3"]) + ["--format", "json"]
    }

    /// Downloads the Pathoplexus row `record`, row `index` of the `totalCount` rows of the batch row
    /// `operationID`, through `lungfish-cli fetch pathoplexus` into
    /// ``genomeRowFolder(projectURL:userDownloads:)``, and returns its bundle (Phase 2.10 lane A45).
    /// Lane A60 of 2.11 deleted the in-process route with its hidden key. `cliURLOverride` names the
    /// CLI a test launches.
    nonisolated static func downloadPathoplexusRow(
        _ record: SearchResultRecord,
        index: Int,
        totalCount: Int,
        operationID: UUID,
        organism: String,
        ncbi: NCBIService,
        includeGFF3Annotations: Bool,
        projectURL: URL?,
        cliURLOverride: URL? = nil
    ) async throws -> URL {
        let download = GenomeRowCLIDownload(
            operationID: operationID, index: index, totalCount: totalCount, cliURLOverride: cliURLOverride)
        return try await download.run(
            pathoplexusFetchArguments(
                accessions: [record.accession.trimmingCharacters(in: .whitespacesAndNewlines)], organism: organism,
                folder: genomeRowFolder(projectURL: projectURL), includeGFF3Annotations: includeGFF3Annotations),
            apiKey: await ncbi.resolvedAPIKey
        )
    }
}
