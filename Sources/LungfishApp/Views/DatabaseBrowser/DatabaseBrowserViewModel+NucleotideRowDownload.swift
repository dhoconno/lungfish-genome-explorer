// DatabaseBrowserViewModel+NucleotideRowDownload.swift - The NCBI browser's nucleotide and virus rows through lungfish-cli fetch ncbi --bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow
import os.log

private let nucleotideRowLogger = Logger(subsystem: LogSubsystem.app, category: "DatabaseBrowserNucleotideRows")

/// The route a nucleotide or virus row of the NCBI browser's batch download takes (Phase 2.10 lane
/// A45, panel decision C4).
enum NucleotideRowDownloadRoute: String, Sendable, Equatable, CaseIterable {
    /// The route before lane A45, kept for one release as the escape the hidden key names (C4).
    /// The app fetches the GenBank record and builds the bundle in process in the batch folder,
    /// under the project's `.tmp` folder, and the import copies it into the Downloads folder. It
    /// names the one sequence by the record's LOCUS name, where the CLI route names it by the
    /// accession with its version, and writes the builder's own record, the declared differences
    /// that keep the key. It goes in 2.11. A download with no project never starts a row, since
    /// the browser refuses it (lane A60).
    case legacy
    /// The default. One `lungfish-cli fetch ncbi <accession> --bundle --output-dir <folder>
    /// --format json` child for each row with a project, which writes straight into the project's
    /// Downloads folder, the folder the row's command names.
    case cli
}

/// Reads the route of the nucleotide rows from the defaults it is given, so a test passes its own
/// suite and never touches the user's defaults.
struct NucleotideRowDownloadRouteSettings {
    /// The hidden key. It holds `cli` or `legacy`, or a Boolean that is true for the CLI route,
    /// for example `defaults write <app id> DatabaseBrowserNucleotideRowRoute legacy`.
    static let defaultsKey = "DatabaseBrowserNucleotideRowRoute"
    /// The route of a key that is unset or holds a value this reader does not know.
    static let defaultRoute: NucleotideRowDownloadRoute = .cli

    let defaults: UserDefaults

    var route: NucleotideRowDownloadRoute {
        switch defaults.object(forKey: Self.defaultsKey) {
        case let name as String:
            return NucleotideRowDownloadRoute(rawValue: name.lowercased()) ?? Self.defaultRoute
        case let usesCLI as Bool:
            return usesCLI ? .cli : .legacy
        default:
            return Self.defaultRoute
        }
    }
}

extension DatabaseBrowserViewModel {
    /// The route of this browser's nucleotide and virus rows, read from the defaults the view model
    /// was given (`sraDownloadSuiteName`, nil for the standard defaults).
    nonisolated var nucleotideRowRoute: NucleotideRowDownloadRoute {
        NucleotideRowDownloadRouteSettings(defaults: sraDownloadDefaults).route
    }

    /// The arguments of `fetch ncbi --bundle` for `accessions` into `folder`. They never hold the
    /// NCBI key, which reaches the child through its environment (SWIFT 6).
    nonisolated static func nucleotideFetchArguments(
        accessions: [String], folder: URL, includeGFF3Annotations: Bool
    ) -> [String] {
        ["fetch", "ncbi"] + accessions + ["--bundle", "--output-dir", folder.path]
            + (includeGFF3Annotations ? [] : ["--no-gff3"]) + ["--format", "json"]
    }

    /// Downloads the nucleotide or virus row `record`, row `index` of the `totalCount` rows of the
    /// batch row `operationID`, by `route`, and returns its bundle. The CLI route writes into
    /// ``genomeRowFolder(projectURL:userDownloads:)`` and never asks for `batchFolder`. The
    /// in-process route builds in `batchFolder`, which makes the folder on its first use.
    /// `cliURLOverride` names the CLI a test launches.
    nonisolated static func downloadNucleotideRow(
        _ record: SearchResultRecord,
        index: Int,
        totalCount: Int,
        operationID: UUID,
        route: NucleotideRowDownloadRoute,
        ncbi: NCBIService,
        genBankVM: GenBankBundleDownloadViewModel,
        includeGFF3Annotations: Bool,
        batchFolder: BatchDownloadFolder,
        projectURL: URL?,
        cliURLOverride: URL? = nil
    ) async throws -> URL {
        let accession = record.accession.trimmingCharacters(in: .whitespacesAndNewlines)
        switch route {
        case .cli:
            let download = GenomeRowCLIDownload(
                operationID: operationID, index: index, totalCount: totalCount, cliURLOverride: cliURLOverride)
            return try await download.run(
                nucleotideFetchArguments(
                    accessions: [accession], folder: genomeRowFolder(projectURL: projectURL),
                    includeGFF3Annotations: includeGFF3Annotations),
                apiKey: await ncbi.resolvedAPIKey
            )
        case .legacy:
            nucleotideRowLogger.info("performBatchDownload: Starting GenBank bundle build for \(accession, privacy: .public)")
            let bundleURL = try await genBankVM.downloadAndBuild(
                accession: record.accession,
                outputDirectory: try batchFolder.url(),
                includeGFF3Annotations: includeGFF3Annotations
            ) { progress, message in
                let overall = (Double(index) + progress) / Double(totalCount)
                performOnMainRunLoop {
                    _ = DownloadCenter.shared.update(
                        id: operationID,
                        progress: overall,
                        detail: "\(record.accession): \(message)"
                    )
                }
            }
            nucleotideRowLogger.info("performBatchDownload: Built GenBank bundle at \(bundleURL.path, privacy: .public)")
            return bundleURL
        }
    }
}
