// AppDelegate+ToolsMenuOperationBegin.swift - Operations panel registration for Tools menu launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// The begin helpers for the Tools menu launches (finding R4). They live
/// here, not beside their launch sites, so the baselined
/// AppDelegate+ToolsMenu.swift does not grow (scripts/ratchets/file-size.sh).
/// Each helper registers its row through `OperationReporting` and calls
/// `launch` only when the row started, so a test can check the row and its
/// command without touching `OperationCenter.shared`. None of these rows
/// locks a bundle, so a real `OperationCenter` never refuses one.
extension AppDelegate {
    // MARK: - NVD and CZ-ID result imports

    /// Registers the NVD Import row and calls `launch` with the operation ID
    /// only when the row started. The row locks no bundle and carries the
    /// Classification type, which replaces the Download label it showed while
    /// the call passed no type.
    ///
    /// The run launches this app executable in `--metagenomics-import-helper`
    /// mode, which is not a `lungfish-cli` flag. The row records the runnable
    /// equivalent, `lungfish-cli import nvd <source> --output-dir <imports>`,
    /// which reaches the same `MetagenomicsImportService.importNvd`.
    ///
    /// Partial CLI parity gap. The helper mode hands the managed samtools to
    /// that service, which then marks duplicates in the copied BAM files and
    /// counts unique reads. `lungfish-cli import nvd` hands it no samtools
    /// path, so a pasted command skips both steps. The command parses, and a
    /// test pins the exact string.
    @discardableResult
    static func beginNvdImportOperation(
        sourceURL: URL,
        importsDirectory: URL,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "NVD Import",
            detail: "Importing \(sourceURL.lastPathComponent)...",
            operationType: .classification,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "import",
                args: ["nvd", sourceURL.path, "--output-dir", importsDirectory.path]
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

    /// Registers the CZ-ID Import row and calls `launch` with the operation ID
    /// only when the row started. The row locks no bundle and carries the
    /// Classification type, which replaces the Download label it showed while
    /// the call passed no type. The launch site registers the row after it
    /// scans the report, so the sample name and the report file name are
    /// known by then.
    ///
    /// The row records `lungfish-cli import cz-id <source> --project <project>
    /// --sample-name <name>`, the command that `CzIdProjectImportWorkflow`
    /// writes into the result's provenance for the same run.
    @discardableResult
    static func beginCzIdImportOperation(
        sourceURL: URL,
        projectURL: URL,
        sampleName: String,
        reportFileName: String,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "CZ-ID Import",
            detail: "Converting \(reportFileName)...",
            operationType: .classification,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "import",
                args: [
                    "cz-id",
                    sourceURL.path,
                    "--project",
                    projectURL.standardizedFileURL.path,
                    "--sample-name",
                    sampleName,
                ]
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

    // MARK: - Viral Recon launch failure

    /// Registers the failed-launch row for a Viral Recon run that could not
    /// start and calls `launch` with the operation ID only when the row
    /// started. The row locks no bundle and carries the Viral Recon type.
    ///
    /// This is a failure report, not a run. The failure happens before the run
    /// builds its command or registers its own row, so no command exists to
    /// record.
    ///
    /// CLI parity gap. The row records no command. The closest real command is
    /// `lungfish-cli workflow run nf-core/viralrecon`, which the run's own row
    /// records once it has a request to build it from.
    @discardableResult
    static func beginViralReconLaunchFailureOperation(
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Viral Recon",
            detail: "Starting Viral Recon",
            operationType: .viralRecon,
            cliCommand: nil,
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

    // MARK: - Read mapping and MAFFT alignment

    /// Registers the Map Reads row for one request and calls `launch` with the
    /// operation ID only when the row started. The row locks no bundle and
    /// carries the Mapping type.
    ///
    /// The row records `lungfish-cli map` as `MappingCLIInvocationBuilder`
    /// builds it from `request`. The command names the bundles the user chose
    /// and leaves `--read-layout` in auto, because `lungfish-cli map` resolves
    /// the bundles' files and the read layout the same way this run does.
    @discardableResult
    static func beginManagedMappingOperation(
        request: MappingRunRequest,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Map Reads (\(request.tool.displayName)): \(request.sampleName)",
            detail: "Mapping \(request.inputFASTQURLs.count) file(s) to \(request.referenceFASTAURL.lastPathComponent)",
            operationType: .mapping,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "map",
                args: MappingCLIInvocationBuilder.arguments(for: request)
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

    /// Registers the MAFFT alignment row and calls `launch` with the operation
    /// ID only when the row started. The row locks no bundle. `cliArguments`
    /// is the argv the runner executes (`CLIMSAAlignmentRunner.buildArguments`),
    /// so the row records the `lungfish-cli align mafft` command the run is.
    @discardableResult
    static func beginMAFFTAlignmentOperation(
        cliArguments: [String],
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Align Sequences (MAFFT)",
            detail: "Preparing MAFFT alignment...",
            operationType: .multipleSequenceAlignmentGeneration,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "align",
                args: Array(cliArguments.dropFirst())
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
}
