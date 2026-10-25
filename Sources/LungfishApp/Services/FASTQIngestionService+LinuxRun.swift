// FASTQIngestionService+LinuxRun.swift - The rows of the plan sheet and of the adopt of a Linux run (CHTC C4 lane U)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow
import os

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
    /// stopping the command. The row ends when the command ends (``runLinuxRunToEnd``). A plan's caller passes the
    /// plan folder as `projectDirectory`, since the finished row names it.
    static func runLinuxRunCommand(
        arguments: [String],
        operationID: UUID,
        projectDirectory: URL,
        onBundleCreated: @escaping @Sendable (URL) -> Void
    ) {
        let runner = CLIImportRunner()
        let task = Task.detached {
            await runLinuxRunToEnd(
                arguments: arguments, operationID: operationID, projectDirectory: projectDirectory,
                runner: runner, onBundleCreated: onBundleCreated
            )
        }
        OperationCenter.shared.setCancelCallback(for: operationID) {
            task.cancel()
            runner.cancel()
        }
    }

    /// What the runner reported of one run, through `onBundleCreated` and `onError`.
    struct LinuxRunOutcome: Sendable, Equatable {
        var bundles: [URL] = []
        var error: String?
    }

    /// How the row of a finished run ends.
    enum LinuxRunRowEnd: Equatable {
        /// The command finished. The adopt made a bundle, or the plan was written to its folder.
        case completed(detail: String, bundleURLs: [URL])
        /// The command stopped after a cancel, so the row is acknowledged as cancelled.
        case cancelled
        /// The command failed, and the runner already failed the row with its message.
        case failedByRunner
    }

    /// How the row ends for what the runner reported. A run with no error ends in the adopt's bundle or, when it made
    /// none, in the plan written to `planFolder`. The two cancel messages are the words `CLIImportRunner.run` gives
    /// `onError` for a cancel before the launch and for a cancel of a run, and the runner leaves the row to its caller.
    nonisolated static func linuxRunRowEnd(_ outcome: LinuxRunOutcome, planFolder: URL) -> LinuxRunRowEnd {
        if let error = outcome.error {
            let cancelled = error == "Import cancelled" || error == "Import cancelled before it started"
            return cancelled ? .cancelled : .failedByRunner
        }
        // A returned batch folder makes a bundle a sample, so the row names the count and links every bundle, the
        // CLI's `Adopted 3 samples` (C5 D2 a, UX-c5 point 7).
        if outcome.bundles.count > 1 {
            return .completed(detail: "Imported \(outcome.bundles.count) samples", bundleURLs: outcome.bundles)
        }
        if let bundle = outcome.bundles.last {
            return .completed(detail: "Imported \(bundle.lastPathComponent)", bundleURLs: outcome.bundles)
        }
        return .completed(detail: "Plan written to \(planFolder.lastPathComponent)", bundleURLs: [])
    }

    /// Runs the command and returns once its row is ended. The runner fails the row for a failure and leaves it for
    /// a success and for a cancel, so the end of the other two is here, with the in-app import's words ("Imported
    /// <bundle>"). A success with no bundle is a plan, which reads "Plan written to <folder>". The hop to the main
    /// actor waits for the main actor, so the row ends after every event the runner handed over before it.
    nonisolated static func runLinuxRunToEnd(
        arguments: [String],
        operationID: UUID,
        projectDirectory: URL,
        runner: CLIImportRunner,
        onBundleCreated: @escaping @Sendable (URL) -> Void
    ) async {
        let outcome = OSAllocatedUnfairLock(initialState: LinuxRunOutcome())
        await runner.run(
            arguments: arguments, operationID: operationID, projectDirectory: projectDirectory,
            onBundleCreated: { bundle in
                outcome.withLock { $0.bundles.append(bundle) }
                onBundleCreated(bundle)
            },
            onError: { message in outcome.withLock { $0.error = message } }
        )
        let end = linuxRunRowEnd(outcome.withLock { $0 }, planFolder: projectDirectory)
        await MainActor.run {
            switch end {
            case let .completed(detail, bundleURLs):
                _ = OperationCenter.shared.complete(id: operationID, detail: detail, bundleURLs: bundleURLs)
            case .cancelled:
                _ = OperationCenter.shared.acknowledgeCancellation(id: operationID, detail: "Cancelled")
            case .failedByRunner:
                break
            }
        }
    }
}
