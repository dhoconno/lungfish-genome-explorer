// DatabaseBrowserViewController+OperationBegin.swift - Operations panel registration for database browser downloads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
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
    /// A download with no project in the route context registers no row,
    /// launches nothing and returns nil. It shows the `No Project Open`
    /// refusal on `presentingWindow`, the browser's own window by default
    /// (Phase 2.11 lane A60, decision C2). Before, it ran in process in a
    /// scratch folder and recorded no command, and the import copied each
    /// bundle into the user's `Downloads/Lungfish Downloads` folder, which
    /// the row never named.
    ///
    /// The command comes from `batchDownloadCLICommand`. NCBI genome
    /// assemblies, nucleotide and virus records and Pathoplexus records
    /// record one. An SRA run row begins with no command, because the import
    /// sheet comes after the row, and the CLI route sets one `fetch sra
    /// download` line for each run when the sheet is confirmed
    /// (`startSRADownloadTask`). Every other download records no command
    /// until a command covers it, as that function describes.
    @discardableResult
    static func beginBatchDownloadOperation(
        title: String,
        accessions: [String],
        source: DatabaseSource,
        searchType: NCBISearchType,
        routeContext: OperationRouteContext?,
        includeGFF3Annotations: Bool = true,
        pathoplexusOrganism: String? = nil,
        presentingWindow: NSWindow? = NSApp?.keyWindow,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult? {
        guard let projectURL = routeContext?.projectURL else {
            refuseBatchDownloadWithoutProject(source: source, searchType: searchType, window: presentingWindow)
            return nil
        }
        let result = reporter.begin(
            title: title,
            detail: "Preparing \(accessions.count) record(s)...",
            operationType: .download,
            cliCommand: batchDownloadCLICommand(
                source: source,
                searchType: searchType,
                accessions: accessions,
                projectURL: projectURL,
                includeGFF3Annotations: includeGFF3Annotations,
                pathoplexusOrganism: pathoplexusOrganism
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

    /// The one refusal of a browser download that has no project to land in, the `No Project
    /// Open` alert that imports and classifier launches show too (decisions C2, U5 and Q-U65).
    /// The download starts nothing, so no row, no folder and no request appears. The alert is a
    /// sheet on `window` when the browser has one and app-modal when it has none, through
    /// ``AppDelegate/NoProjectPresenterSeam``. It names no folder.
    static func refuseBatchDownloadWithoutProject(source: DatabaseSource, searchType: NCBISearchType, window: NSWindow?) {
        AppDelegate.NoProjectPresenterSeam.presenter.present(
            title: "No Project Open",
            message: "Open or create a project before downloading \(noProjectDownloadNoun(source: source, searchType: searchType)).",
            on: window
        )
    }

    /// What a browser download brings in, as the `No Project Open` refusal names it.
    static func noProjectDownloadNoun(source: DatabaseSource, searchType: NCBISearchType) -> String {
        switch source {
        case .ncbi:
            switch searchType {
            case .genome: return "genome assemblies"
            case .nucleotide: return "GenBank records"
            case .virus: return "virus records"
            }
        case .pathoplexus: return "Pathoplexus records"
        case .ena: return "SRA runs"
        case .ddbj, .local: return "records"
        }
    }

    /// The `lungfish-cli fetch` command a batch download row records, or nil
    /// when no command reproduces the download. It is nil with no project, a
    /// download `beginBatchDownloadOperation` refuses before it asks.
    ///
    /// - NCBI genome assemblies, one or several, record `fetch genome
    ///   <accessions> --output-dir <folder> --format json`. The run launches
    ///   that command for each row in turn (lane A44,
    ///   DatabaseBrowserViewModel+GenomeRowDownload.swift), and each bundle's
    ///   record names its own accession, so one line with every accession
    ///   builds the same bundles. The folder is the project's Downloads folder,
    ///   which the run writes into and the import keeps in place.
    /// - SRA runs begin with no command. The import sheet comes after the
    ///   row, and its settings are flags of the command, so
    ///   `startSRADownloadTask` (DatabaseBrowserViewModel+SRARowDownload.swift)
    ///   sets one `fetch sra download <run> --bundle --project <project> <the
    ///   sheet's flags> --format json` line for each run when the sheet is
    ///   confirmed (lane A45 M3).
    /// - NCBI nucleotide and virus records, with a project, record `fetch ncbi
    ///   <accessions> --bundle --output-dir <folder> [--no-gff3] --format
    ///   json` (lane A45). The run launches it for each row in turn into the
    ///   project's Downloads folder, and each bundle's record names its own
    ///   accession, so one line with every accession builds the same bundles.
    ///   `--no-gff3` is the browser's GFF3 setting turned off.
    /// - Pathoplexus records, with a project, record `fetch pathoplexus
    ///   <accessions> --organism <id> --output-dir <folder> [--no-gff3]
    ///   --format json` (lane A45). Its accessions are not NCBI accessions, so
    ///   the organism names the Pathoplexus the records are read from. The run
    ///   launches it for each row in turn into the project's Downloads folder,
    ///   and each bundle's record names its own accession, so one line with
    ///   every accession builds the same bundles.
    static func batchDownloadCLICommand(
        source: DatabaseSource,
        searchType: NCBISearchType,
        accessions: [String],
        projectURL: URL?,
        includeGFF3Annotations: Bool = true,
        pathoplexusOrganism: String? = nil
    ) -> String? {
        guard !accessions.isEmpty, let projectURL else { return nil }
        let folder = genomeRowFolder(projectURL: projectURL)
        if source == .pathoplexus {
            guard let organism = pathoplexusOrganism, !organism.isEmpty else { return nil }
            return OperationCenter.buildCLICommand(
                subcommand: "fetch pathoplexus",
                args: Array(pathoplexusFetchArguments(
                    accessions: accessions, organism: organism, folder: folder, includeGFF3Annotations: includeGFF3Annotations
                ).dropFirst(2))
            )
        }
        guard source == .ncbi else { return nil }
        switch searchType {
        case .genome:
            return OperationCenter.buildCLICommand(
                subcommand: "fetch genome",
                args: Array(genomeFetchArguments(accessions: accessions, folder: folder).dropFirst(2))
            )
        case .nucleotide, .virus:
            return OperationCenter.buildCLICommand(
                subcommand: "fetch ncbi",
                args: Array(nucleotideFetchArguments(
                    accessions: accessions, folder: folder, includeGFF3Annotations: includeGFF3Annotations
                ).dropFirst(2))
            )
        default:
            return nil
        }
    }
}
