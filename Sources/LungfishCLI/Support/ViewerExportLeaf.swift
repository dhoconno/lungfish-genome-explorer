// ViewerExportLeaf.swift - How every viewer export leaf runs, refuses, fails and cancels
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow

/// A viewer export leaf's refusal, which exits 3 before the leaf writes anything (`ADDING-AN-OPERATION.md`, the
/// command's side of the row). Its message names the fix.
struct ViewerExportRefusal: Error, LocalizedError, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// What a viewer export leaf wrote, with the closing line it prints, which names no full path.
struct ViewerExportLeafOutcome: Sendable {
    let outputURL: URL
    let message: String
}

/// The run every viewer export leaf shares (Phase 2.12 lane 12.31, ARCH ruling 1.6).
///
/// The leaf's export runs under `runCancellingOnSIGTERM`, the scope every SIGTERM-converting leaf shares. A refusal
/// exits 3, a failure exits 64 and a cancel exits 125. The export writes its payload and record in one `ScientificFileExportProvenance.writeAtomically`
/// transaction, so a cancel rolls both back and leaves no output and no sidecar. With `--format json` standard output
/// holds only events.
enum ViewerExportLeaf {
    /// The words of a cancelled export.
    static let cancelledMessage = "The export was cancelled. No file was written."

    /// A test seam. When this variable names a file, the export creates that file once its payload is staged and
    /// then waits up to 30 seconds for its cancel, so a SIGTERM test reaches the leaf inside its transaction.
    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"

    /// Runs `export` and turns how it ended into the events, the human line and the exit status.
    static func run(
        globalOptions: GlobalOptions,
        startMessage: String,
        export: @escaping @Sendable (CLIEventEmitter) async throws -> ViewerExportLeafOutcome
    ) async throws {
        let eventsOn = globalOptions.outputFormat == .json
        let events = CLIEventEmitter(enabled: eventsOn, emit: printEventLine)
        events.emitStart(message: startMessage)
        let outcome = await runCancellingOnSIGTERM { try await export(events) }
        switch outcome {
        case .success(let written):
            events.emitComplete(output: written.outputURL.path, message: written.message)
            if !globalOptions.quiet {
                printHumanLine(written.message, eventsOn: eventsOn)
            }
        case .failure(let error) where error is CancellationError:
            events.emitFailed(cancelledMessage)
            printHumanLine(cancelledMessage, eventsOn: eventsOn)
            throw CLIExitCode.cancelled.exitCode
        case .failure(let error) where error is ViewerExportRefusal:
            events.emitFailed(CLIFailureWords.describe(error))
            printHumanLine(CLIFailureWords.describe(error), eventsOn: eventsOn)
            throw CLIExitCode.inputError.exitCode
        case .failure(let error):
            events.emitFailed(CLIFailureWords.describe(error))
            printHumanLine(CLIFailureWords.describe(error), eventsOn: eventsOn)
            throw CLIExitCode.workflowError.exitCode
        }
    }

    /// Refuses, before anything is written, an output that is one of the files the export reads, an output whose
    /// folder is missing, and an output file that exists unless `force` is set, as `tree export subtree` does.
    static func refuseUnsafeOutput(_ outputURL: URL, inputs: [URL], force: Bool) throws {
        func resolved(_ url: URL) -> String {
            url.standardizedFileURL.resolvingSymlinksInPath().path
        }
        if inputs.contains(where: { resolved($0) == resolved(outputURL) }) {
            throw ViewerExportRefusal("The output \(outputURL.path) is a file the export reads. Choose another output file.")
        }
        let folder = outputURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ViewerExportRefusal("No folder at \(folder.path) to write the output in. Create it or choose another output file.")
        }
        if FileManager.default.fileExists(atPath: outputURL.path), !force {
            throw ViewerExportRefusal("Output file already exists: \(outputURL.path). Use --force to overwrite.")
        }
    }

    /// Called inside the transaction once the payload is staged. In a debug build it holds for a SIGTERM test when
    /// ``holdFileVariable`` is set, then stops if the export was cancelled, so the transaction rolls back. Tests run
    /// the debug `lungfish-cli`, and a release build carries no hold.
    static func checkpointAfterStaging() throws {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment[holdFileVariable], !path.isEmpty {
            FileManager.default.createFile(atPath: path, contents: Data())
            let deadline = Date().addingTimeInterval(120)
            while !Task.isCancelled, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        #endif
        try Task.checkCancellation()
    }
}
