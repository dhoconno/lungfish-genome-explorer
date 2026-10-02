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
    /// The command comes from `batchDownloadCLICommand`. It is the closest
    /// `lungfish-cli fetch` command for the source, and none of the three
    /// reproduces the whole run, as that function describes. The recorded
    /// commands stay a CLI parity gap until a command covers them.
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
                accessions: accessions
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

    /// The `lungfish-cli fetch` command a batch download row records. The output
    /// is the current directory, because the run writes to a temporary folder
    /// and imports from there.
    ///
    /// - SRA runs record `fetch sra download <accession> --output-dir .`. It
    ///   reproduces the download step for one run. The run also imports the
    ///   FASTQ files into the project with the settings the user confirmed in
    ///   the import sheet, and no part of the row records that step.
    /// - NCBI genome assemblies record `fetch genome <accession> --output-dir .`.
    ///   It builds the same kind of `.lungfishref` bundle from the assembly's
    ///   FASTA and GFF3. The row used to record `fetch genome --accession
    ///   <accessions> -o .`, which the CLI never parsed, because `fetch genome`
    ///   takes the accession as an argument and names its folder with
    ///   `--output-dir`.
    /// - Every other source keeps the `fetch ncbi <accessions> --save-to .` the
    ///   row recorded before. That covers NCBI nucleotide and virus records and
    ///   Pathoplexus records.
    ///
    /// CLI parity gaps. `fetch sra download` and `fetch genome` take one
    /// accession, so a batch of several records keeps the flat list the row
    /// recorded before, which the CLI rejects. Running the command once per
    /// accession is the closest reproduction. `fetch ncbi` saves one GenBank
    /// file where the run builds one `.lungfishref` bundle for every record, and
    /// it refuses `--save-to .` at run time, because that path is a directory.
    /// `fetch genome <accession>` also builds a bundle from a nucleotide record,
    /// with a layout of its own, and is the closest command. Pathoplexus has no
    /// fetch command, and its accessions are not NCBI accessions, so that row
    /// cannot be reproduced at all.
    static func batchDownloadCLICommand(
        source: DatabaseSource,
        searchType: NCBISearchType,
        accessions: [String]
    ) -> String {
        if source == .ena {
            return OperationCenter.buildCLICommand(
                subcommand: "fetch sra download",
                args: accessions + ["--output-dir", "."]
            )
        }
        if source == .ncbi && searchType == .genome {
            return OperationCenter.buildCLICommand(
                subcommand: "fetch genome",
                args: accessions + ["--output-dir", "."]
            )
        }
        return OperationCenter.buildCLICommand(
            subcommand: "fetch ncbi",
            args: accessions + ["--save-to", "."]
        )
    }
}
