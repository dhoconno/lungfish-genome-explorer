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
    /// The command comes from `batchDownloadCLICommand`. Only a single NCBI
    /// genome assembly with a project in the route context records one. Every
    /// other download records no command until a command covers it, as that
    /// function describes.
    ///
    /// - cli-parity-gap: download-sra. Every SRA run download.
    /// - cli-parity-gap: download-genome-batch. Two or more genome assemblies.
    /// - cli-parity-gap: download-genome-no-project. One genome assembly with
    ///   no project in the route context.
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
    /// - One NCBI genome assembly with a project records `fetch genome
    ///   <accession> --output-dir <project>/Downloads`. It builds the same kind of
    ///   `.lungfishref` bundle from the assembly's FASTA and GFF3. The run
    ///   builds the bundle in a temporary folder, and the completed download is
    ///   copied into the project's Downloads folder
    ///   (`handleMultipleDownloadsSync`), so that is the folder the command
    ///   names (R3). With no project in the route context the run picks the
    ///   folder from the window it lands in, which this function cannot know,
    ///   so it records nil then, because a command path must be absolute. The
    ///   run also
    ///   names the bundle `<organism> - <assembly name>` from the assembly
    ///   summary it fetches, where `fetch genome` names it
    ///   `<organism>_<accession>` unless `--name` is given, so the two bundles
    ///   differ in name.
    /// - Two or more genome assemblies record nil, because `fetch genome`
    ///   takes one accession.
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
        projectURL: URL?
    ) -> String? {
        guard source == .ncbi, searchType == .genome, accessions.count == 1, let projectURL else { return nil }
        let downloads = projectURL.appendingPathComponent("Downloads", isDirectory: true).path
        return OperationCenter.buildCLICommand(
            subcommand: "fetch genome",
            args: accessions + ["--output-dir", downloads]
        )
    }
}
