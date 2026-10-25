// FASTQIngestionService+LinuxRun.swift - The rows of the plan sheet and of the adopt of a Linux run (CHTC C4 lane U)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow

extension FASTQIngestionService {
    /// The argv after `lungfish-cli` of the adopt the app runs, `import fastq <folder> --adopt --project <project>
    /// --format json`. It is `ExecutorRunAdoption.cliArguments`, the array the adopt records as its envelope's argv,
    /// so the Operations row, the run and the record name one command (ARCH 2).
    nonisolated static func linuxRunAdoptArguments(resultFolder: URL, projectDirectory: URL) -> [String] {
        ExecutorRunAdoption.cliArguments(resultFolder: resultFolder, projectDirectory: projectDirectory, eventsOn: true)
    }

    /// Registers the row of the adopt of `resultFolder` and, only when it starts, calls `launch` with the operation ID
    /// and the argv the row records. The bundle's name comes from the run, so the row locks no bundle.
    @discardableResult
    static func beginLinuxRunAdoptOperation(
        resultFolder: URL,
        projectDirectory: URL,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID, [String]) -> Void
    ) -> OperationStartResult {
        let arguments = linuxRunAdoptArguments(resultFolder: resultFolder, projectDirectory: projectDirectory)
        let result = reporter.begin(
            title: "Linux Run Result: \(resultFolder.lastPathComponent)",
            detail: "Checking the returned folder\u{2026}",
            operationType: .ingestion,
            cliCommand: CLIImportRunner.commandLine(arguments: arguments),
            routeContext: routeContext
        )
        if case .started(let operationID) = result { launch(operationID, arguments) }
        return result
    }

    /// Registers the row of the plan sheet's `import fastq --write-plan` and, only when it starts, calls `launch` with
    /// the operation ID and the argv the row records.
    @discardableResult
    static func beginLinuxPlanOperation(
        request: FASTQPlanSheetRequest,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID, [String]) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Plan for a Linux Machine: \(request.planFolder.lastPathComponent)",
            detail: "Writing the plan\u{2026}",
            operationType: .ingestion,
            cliCommand: CLIImportRunner.commandLine(arguments: request.arguments),
            routeContext: routeContext
        )
        if case .started(let operationID) = result { launch(operationID, request.arguments) }
        return result
    }

    /// Runs `import fastq` with `arguments` for the row `operationID`, as the FASTQ imports do, with the row's Cancel
    /// stopping the command.
    static func runLinuxRunCommand(
        arguments: [String],
        operationID: UUID,
        projectDirectory: URL,
        onBundleCreated: @escaping @Sendable (URL) -> Void
    ) {
        let runner = CLIImportRunner()
        let task = Task.detached {
            await runner.run(
                arguments: arguments, operationID: operationID, projectDirectory: projectDirectory,
                onBundleCreated: onBundleCreated, onError: { _ in }
            )
        }
        OperationCenter.shared.setCancelCallback(for: operationID) {
            task.cancel()
            runner.cancel()
        }
    }
}
