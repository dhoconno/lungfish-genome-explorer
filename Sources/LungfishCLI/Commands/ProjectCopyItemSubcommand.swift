// ProjectCopyItemSubcommand.swift - Copy a project item into another project
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// A refusal of `project copy-item` before it writes anything, which exits 3 and names the fix.
struct ProjectCopyItemRefusal: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ProjectCopyItemSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy-item",
        abstract: "Copy a project item into another project",
        discussion: """
            Copies one Lungfish bundle or analysis result folder into a project, as dropping it onto
            the sidebar of another project window does. The item keeps its folder from the source
            project, or goes to the folder its kind uses, or to --folder. A name the project already
            holds gets a counter, such as NC_045512-2.lungfishref. The copy is built in the project's
            .tmp folder, where its links into the source project are rewritten and its record names
            the source item by its path inside the source project and the SHA-256 of every file the
            copy read. It is then published with one rename, so no reader sees a part of it. SIGTERM
            stops the copy before it publishes, records it as cancelled and exits 125. A refusal
            exits 3.

            Examples:
              lungfish-cli project copy-item "Reference Sequences/NC_045512.lungfishref" --source-project A.lungfish --project B.lungfish
              lungfish-cli project copy-item Imports/HG002.lungfishfastq --source-project A.lungfish --project B.lungfish --folder Imports/Reviewed --format json
            """
    )

    /// The workflow and tool name the copy's records give.
    static let commandName = "lungfish project copy-item"
    static let cancelledMessage = "Copy cancelled. Nothing was published."

    @Argument(help: "The item to copy, as its path inside --source-project, or an absolute path for an item in no project")
    var item: String

    @Option(name: .customLong("source-project"), help: "The project that holds the item. Defaults to the project the item's path is inside")
    var sourceProject: String?

    @Option(name: .customLong("project"), help: "The project to copy the item into")
    var project: String

    @Option(
        name: .customLong("folder"),
        help: "The folder to copy into, as a path inside --project. Defaults to the item's folder in its project, or the folder its kind uses"
    )
    var folder: String?

    @OptionGroup var globalOptions: GlobalOptions

    /// With `--format json` standard output holds only `CLIEvent` lines, with the words the app's row
    /// shows. SIGTERM, the app's Cancel, stops the copy before it publishes, records it as cancelled and
    /// exits 125. A refusal exits 3 and any other failure 64.
    func run() async throws {
        let eventsOn = globalOptions.outputFormat == .json
        let events = CLIEventEmitter(enabled: eventsOn, emit: printEventLine)
        let startedAt = Date()
        let pendingCancel = PendingTaskCancel<Result<CrossProjectItemCopier.Outcome, any Error>>()
        let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
        let command = self
        let task = Task { () -> Result<CrossProjectItemCopier.Outcome, any Error> in
            do {
                return .success(try command.copyItem(events: events))
            } catch {
                return .failure(Task.isCancelled ? CancellationError() : error)
            }
        }
        pendingCancel.attach(task)
        let outcome = await task.value
        termination.end()
        switch outcome {
        case .success(let copied):
            let name = copied.destinationURL.lastPathComponent
            events.emitComplete(output: copied.destinationURL.path, message: "Copied \(name)")
            if !globalOptions.quiet {
                printHumanLine("Copied \(copied.sourceURL.lastPathComponent) to \(copied.destinationURL.path)", eventsOn: eventsOn)
            }
        case .failure(let error) where error is CancellationError:
            await recordCancelledRun(startedAt: startedAt)
            events.emitFailed(Self.cancelledMessage)
            printHumanLine(Self.cancelledMessage, eventsOn: eventsOn)
            throw CLIExitCode.cancelled.exitCode
        case .failure(let error) where error is ProjectCopyItemRefusal || error is CrossProjectItemCopier.CopyError:
            events.emitFailed(CLIFailureWords.describe(error))
            printHumanLine(CLIFailureWords.describe(error), eventsOn: eventsOn)
            throw CLIExitCode.inputError.exitCode
        case .failure(let error):
            events.emitFailed(CLIFailureWords.describe(error))
            printHumanLine(CLIFailureWords.describe(error), eventsOn: eventsOn)
            throw CLIExitCode.workflowError.exitCode
        }
    }

    /// The copy, which runs inside the task the SIGTERM cancels and checks for the cancel before each
    /// file it reads and before it publishes.
    func copyItem(events: CLIEventEmitter) throws -> CrossProjectItemCopier.Outcome {
        events.emitStart("Copying \(URL(fileURLWithPath: item).lastPathComponent)")
        let request = try resolvedRequest()
        events.emitProgress(
            0, message: "Copying \(request.source.lastPathComponent) into \(request.target.lastPathComponent)\u{2026}"
        )
        let outcome = try CrossProjectItemCopier.copy(
            itemAt: request.source,
            intoProject: request.target,
            requestedFolder: request.folder,
            now: Self.copiedAt(),
            identity: .command(request.identity),
            checkCancellation: { try Task.checkCancellation() }
        )
        for line in outcome.record.missingSourceSummaryLines {
            events.emitLog(.warning, line)
        }
        return outcome
    }

    /// The variable a debug build reads for the time `project-copy.json` names, so a parity class gives each
    /// side one clock (BIO ruling on `caller`, answer 2). The route parity harness reads that record as a
    /// payload, which no wall-clock mask covers.
    static let copiedAtVariable = "LUNGFISH_TEST_COPIED_AT"

    /// The time the copy record names. The clock, or in a debug build the ISO 8601 time `copiedAtVariable` holds.
    static func copiedAt(environment: [String: String] = ProcessInfo.processInfo.environment) -> Date {
        #if DEBUG
        if let text = environment[copiedAtVariable], let date = ISO8601DateFormatter().date(from: text) {
            return date
        }
        #endif
        return Date()
    }

    /// Records the run a cancel stopped as cancelled, in the folder the item would have gone to when it
    /// exists and in the project otherwise, so the cancel makes no folder. A failure to write it does
    /// not hide the cancel.
    private func recordCancelledRun(startedAt: Date) async {
        guard let request = try? resolvedRequest() else { return }
        let folder = CrossProjectItemCopier.destinationFolder(
            for: request.kind,
            sourceURL: request.source,
            sourceProjectURL: request.sourceProject,
            targetProjectURL: request.target,
            requestedFolder: request.folder
        )
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
        _ = try? await CLIProvenanceSupport.recordSingleStepRun(
            name: Self.commandName,
            parameters: request.identity.explicitOptions,
            toolName: Self.commandName,
            toolVersion: LungfishCLI.configuration.version,
            command: request.identity.argv,
            inputs: [],
            outputs: [],
            exitCode: CLIExitCode.cancelled.exitCode.rawValue,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: Self.cancelledMessage,
            status: .cancelled,
            outputDirectory: exists ? folder : request.target,
            writeFileSidecars: false
        )
    }
}
