// DatabaseBrowserViewController+OperationBegin.swift - Operations panel registration for database browser downloads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit

/// The begin helper for the batch download launch in the baselined
/// DatabaseBrowserViewController.swift (finding R4). The launch is a method of
/// `DatabaseBrowserViewModel`, which that file declares, and the helper lives
/// here so the baselined file does not grow (scripts/ratchets/file-size.sh).
/// The helper registers its row through `OperationReporting` and calls `launch`
/// only when the row started, so a test can check the row and its command
/// without touching `OperationCenter.shared`.
extension DatabaseBrowserViewModel {
    /// Registers the batch download row for the NCBI, SRA and Pathoplexus
    /// browser and, only when it starts, calls `launch` with the operation ID.
    /// The row is a download row and locks no bundle. `title` is the descriptive
    /// title the Downloads popover shows, built from the first accessions.
    ///
    /// The command comes from `batchDownloadCLICommand`. NCBI genome
    /// assemblies record one, with a project in the route context or none.
    /// Every other download records no command until a command covers it, as
    /// that function describes.
    ///
    /// - cli-parity-gap: download-sra. Every SRA run download.
    /// - cli-parity-gap: download-ncbi-bundle. NCBI nucleotide and virus
    ///   records, and any other source `fetch` cannot read.
    /// - cli-parity-gap: download-pathoplexus. Pathoplexus records.
    @discardableResult
    static func beginBatchDownloadOperation(
        title: String,
        accessions: [String],
        source: DatabaseSource,
        searchType: NCBISearchType,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: title,
            detail: "Preparing \(accessions.count) record(s)...",
            operationType: .download,
            cliCommand: batchDownloadCLICommand(
                source: source,
                searchType: searchType,
                accessions: accessions,
                projectURL: routeContext?.projectURL
            ),
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// The `lungfish-cli fetch` command a batch download row records, or nil
    /// when no command reproduces the download.
    ///
    /// - NCBI genome assemblies, one or several, record `fetch genome
    ///   <accessions> --output-dir <folder> --format json`. The run launches
    ///   that command for each row in turn (lane A44,
    ///   DatabaseBrowserViewModel+GenomeRowDownload.swift), and each bundle's
    ///   record names its own accession, so one line with every accession
    ///   builds the same bundles. The folder is the project's Downloads folder,
    ///   or the user's Downloads folder with no project in the route context
    ///   (`genomeRowFolder(projectURL:userDownloads:)`), which the run writes
    ///   into. The in-process route behind the hidden key builds the same
    ///   bundles with no record, a difference the parity class declares.
    /// - SRA runs record nil. `fetch sra download` downloads one run, and the
    ///   run then imports the FASTQ files into the project with the settings
    ///   the user confirmed in the import sheet, which no command does.
    /// - NCBI nucleotide and virus records record nil. `fetch ncbi` saves one
    ///   GenBank file where the run builds one `.lungfishref` bundle for every
    ///   record. `fetch genome <accession>` also builds a bundle from a
    ///   nucleotide record, with a layout of its own, and is the closest
    ///   command.
    /// - Pathoplexus records record nil. No fetch command reads Pathoplexus,
    ///   and its accessions are not NCBI accessions.
    static func batchDownloadCLICommand(
        source: DatabaseSource,
        searchType: NCBISearchType,
        accessions: [String],
        projectURL: URL?,
        userDownloads: URL = userDownloadsFolder
    ) -> String? {
        guard source == .ncbi, searchType == .genome, !accessions.isEmpty else { return nil }
        let folder = genomeRowFolder(projectURL: projectURL, userDownloads: userDownloads)
        return OperationCenter.buildCLICommand(
            subcommand: "fetch genome",
            args: Array(genomeFetchArguments(accessions: accessions, folder: folder).dropFirst(2))
        )
    }
}
