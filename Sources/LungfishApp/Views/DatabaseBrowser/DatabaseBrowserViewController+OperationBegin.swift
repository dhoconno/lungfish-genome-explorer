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
    /// assemblies, nucleotide and virus records and Pathoplexus records with
    /// a project in the route context record one. Every other download
    /// records no command until a command covers it, as that function
    /// describes.
    ///
    /// - cli-parity-gap: download-sra. Every SRA run download.
    /// - cli-parity-gap: download-genome-no-project. NCBI genome assemblies,
    ///   nucleotide records, virus records and Pathoplexus records with no
    ///   project in the route context (lane A45 widened it from genome
    ///   assemblies).
    @discardableResult
    static func beginBatchDownloadOperation(
        title: String,
        accessions: [String],
        source: DatabaseSource,
        searchType: NCBISearchType,
        routeContext: OperationRouteContext?,
        includeGFF3Annotations: Bool = true,
        pathoplexusOrganism: String? = nil,
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
                projectURL: routeContext?.projectURL,
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

    /// The `lungfish-cli fetch` command a batch download row records, or nil
    /// when no command reproduces the download.
    ///
    /// - NCBI genome assemblies, one or several, record `fetch genome
    ///   <accessions> --output-dir <folder> --format json`. The run launches
    ///   that command for each row in turn (lane A44,
    ///   DatabaseBrowserViewModel+GenomeRowDownload.swift), and each bundle's
    ///   record names its own accession, so one line with every accession
    ///   builds the same bundles. The folder is the project's Downloads folder,
    ///   which the run writes into and the import keeps in place. With no
    ///   project in the route context the row records nil and runs in process,
    ///   because the import copies a bundle from outside a project into its own
    ///   folder and deletes the one it was given
    ///   (AppDelegate+Classification.swift). The in-process route behind the
    ///   hidden key builds the same bundles with no record, a difference the
    ///   parity class declares.
    /// - SRA runs record nil. `fetch sra download` downloads one run, and the
    ///   run then imports the FASTQ files into the project with the settings
    ///   the user confirmed in the import sheet, which no command does.
    /// - NCBI nucleotide and virus records, with a project, record `fetch ncbi
    ///   <accessions> --bundle --output-dir <folder> [--no-gff3] --format
    ///   json` (lane A45). The run launches it for each row in turn into the
    ///   project's Downloads folder, and each bundle's record names its own
    ///   accession, so one line with every accession builds the same bundles.
    ///   `--no-gff3` is the browser's GFF3 setting turned off. With no project
    ///   the row records nil and runs in process, for the reason the genome
    ///   assemblies give.
    /// - Pathoplexus records, with a project, record `fetch pathoplexus
    ///   <accessions> --organism <id> --output-dir <folder> [--no-gff3]
    ///   --format json` (lane A45). Its accessions are not NCBI accessions, so
    ///   the organism names the Pathoplexus the records are read from. The run
    ///   launches it for each row in turn into the project's Downloads folder,
    ///   and each bundle's record names its own accession, so one line with
    ///   every accession builds the same bundles. With no project the row
    ///   records nil and runs in process, for the reason the genome
    ///   assemblies give.
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
