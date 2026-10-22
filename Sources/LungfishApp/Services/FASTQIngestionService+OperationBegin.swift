// FASTQIngestionService+OperationBegin.swift - Operations panel registration for FASTQ ingestion launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// The begin helpers for the launches in FASTQIngestionService.swift (finding
/// R4). They live here, not beside their launch sites, so the baselined
/// launch-site file does not grow (scripts/ratchets/file-size.sh). Each helper
/// registers its row through `OperationReporting` and calls `launch` only when
/// the row started, so a test can check the row and its command without
/// touching `OperationCenter.shared`.
///
/// None of the three launches declares a bundle lock, so `begin` cannot refuse
/// them on a real `OperationCenter` today. Each launch still switches on the
/// result and runs nothing on a refusal, which keeps it correct if a lock is
/// added later. The two launches that take a `completion` also deliver the
/// refusal through it as an `OperationRefusedError`, so the caller's progress
/// indicator and continuation are released.
extension FASTQIngestionService {
    // MARK: - In-place ingestion

    /// Registers the in-place ingestion row and, only when it starts, calls
    /// `launch` with the operation ID. The row locks no bundle.
    ///
    /// The run is `lungfish-cli fastq ingest` (Phase 2.10 lane A47 M3). It clumpifies and compresses
    /// the FASTQ file in place, writes the FASTQ metadata sidecar and a record that names the original's
    /// digest, and only then deletes the original. `cliArguments` is the argv the route runs, built once
    /// by ``inPlaceIngestionCLIArguments(url:pairingMode:pairedFile:threads:)``, and the row records it.
    @discardableResult
    static func beginInPlaceIngestionOperation(
        url: URL,
        routeContext: OperationRouteContext?,
        cliArguments: [String]? = nil,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "FASTQ Ingestion: \(FASTQIngestionPipeline.deriveBaseName(from: url))",
            detail: "Preparing...",
            operationType: .ingestion,
            // The CLI route passes the argv it runs, so the row records the command it ran (lane A47 M3).
            cliCommand: cliArguments.map { OperationCenter.buildCLICommand(subcommand: "", args: $0) },
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

    // MARK: - Bundle imports through lungfish-cli

    /// Registers the single-file import row and, only when it starts, calls
    /// `launch` with the operation ID. The row locks no bundle.
    ///
    /// The run executes `lungfish-cli import fastq` with the arguments of
    /// ``cliImportArguments(pair:projectDirectory:importConfig:bundleName:force:)``
    /// for ``legacySingleFileImportConfiguration(for:)``, so the row records
    /// the command built from those same values. The row used to leave out
    /// `--name`, which the run passes.
    @discardableResult
    static func beginSingleFileImportOperation(
        sourceURL: URL,
        projectDirectory: URL,
        bundleName: String,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "FASTQ Import: \(bundleName)",
            detail: "Preparing import workspace\u{2026}",
            operationType: .ingestion,
            cliCommand: cliImportCommandPreview(
                sourceURL: sourceURL,
                projectDirectory: projectDirectory,
                bundleName: bundleName
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

    /// Registers the import row for a FASTQ pair and its Import sheet settings
    /// and, only when it starts, calls `launch` with the operation ID. The row
    /// locks no bundle.
    ///
    /// The run executes `lungfish-cli import fastq` with the arguments of
    /// ``cliImportArguments(pair:projectDirectory:importConfig:bundleName:force:)``
    /// and the row records the command built from those same values.
    ///
    /// A started row first logs the sample's pairing notices, why the
    /// sheet's grouping left a file of another folder out of it. The run
    /// names this sample's files alone, so its CLI cannot say why, and the
    /// row logs each notice in the line `CLIImportRunner` logs for the CLI's
    /// own notices (re-review N1).
    @discardableResult
    static func beginFASTQPairImportOperation(
        pair: FASTQFilePair,
        projectDirectory: URL,
        bundleName: String,
        importConfig: FASTQImportConfiguration,
        forceReplace: Bool,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "FASTQ Import: \(bundleName)",
            detail: "Preparing import workspace\u{2026}",
            operationType: .ingestion,
            cliCommand: cliImportCommandPreview(
                pair: pair,
                projectDirectory: projectDirectory,
                importConfig: importConfig,
                bundleName: bundleName,
                force: forceReplace
            ),
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            for notice in pair.pairingNotices {
                reporter.log(
                    id: operationID,
                    level: .warning,
                    message: CLIImportRunner.noticeLine(sample: notice.sample, message: notice.message)
                )
            }
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// The import configuration of the single-file entry point
    /// `ingestAndBundle(sourceURL:projectDirectory:bundleName:routeContext:completion:)`.
    /// Nobody chose the pairing, so the CLI detects it from the records. The
    /// run and its recorded command both build their arguments from this value.
    nonisolated static func legacySingleFileImportConfiguration(for sourceURL: URL) -> FASTQImportConfiguration {
        FASTQImportConfiguration(
            inputFiles: [sourceURL],
            detectedPlatform: .unknown,
            confirmedPlatform: .unknown,
            pairingMode: .singleEnd,
            pairingModeIsUserChoice: false,
            qualityBinning: QualityBinningScheme.importDefault,
            skipClumpify: false,
            deleteOriginals: false,
            postImportRecipe: nil,
            resolvedPlaceholders: [:],
            recipeName: nil,
            compressionLevel: nil
        )
    }
}
