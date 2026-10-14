// DemoFetchReporter.swift - The events and human text of lungfish-cli demo fetch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow
import os

/// How a `demo fetch` run ended.
enum DemoFetchOutcome: Sendable {
    /// The project was downloaded, verified and moved into place.
    case installed(title: String, DemoProjectInstallResult)
    /// A copy was already there and `--force` was not given, so nothing was downloaded.
    case alreadyInstalled(title: String, projectURL: URL)
    /// Anything else that ended the run. The error keeps its own words.
    case failed(any Error)
    /// A SIGTERM, which the Operations panel's Cancel sends, stopped the run.
    case cancelled
}

/// Writes what `demo fetch` prints (Phase 2.10 lane A45 M4, panel decision C9).
///
/// With `--format json` a run is one `start` line, `progress` lines and one `complete` line or one
/// `failed` line on standard output, and nothing else. The download takes the first nine tenths of the
/// bar as the share of the bytes received, one line for each whole percent, then verifying sits at 0.91,
/// unpacking at 0.93 and installing at 0.98, and the bar never steps back. Each line carries the words
/// the Demo Projects window shows for the same phase (`DemoProjectsViewModel.detailText`), and the window
/// reads a line back into its phase from these numbers (`DemoProjectCLIProgress`). The `complete` line
/// names the installed project folder and no artifact, because a project folder is no bundle. A copy that
/// was already there ends with `start` and `complete` and no progress. The notice of a replaced copy is a
/// `log` line. The command printed the project's record with `--format json` before 2.10, and `demo info
/// <id> --format json` prints it now.
///
/// With events off the text is what the command always printed: the path on standard output, and the
/// notices and the progress on standard error. `--quiet` drops the notices and the progress.
final class DemoFetchReporter: Sendable {
    let eventsOn: Bool
    private let id: String
    private let quiet: Bool
    private let interactive: Bool
    private let events: CLIEventEmitter
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var highest = 0.0
        var lastPercent = -1
        var reported = false
    }

    /// The share of the bar the download takes.
    static let downloadShare = 0.9
    /// Where verifying, unpacking and installing sit on the bar.
    static let verifyingFraction = 0.91
    static let extractingFraction = 0.93
    static let installingFraction = 0.98
    /// The words of the `failed` line of a run a SIGTERM ended, which the app reads as Cancelled.
    static let cancelledMessage = "Fetch cancelled"

    /// - Parameter interactive: Standard error is a terminal, so text mode shows the download's percent.
    init(id: String, eventsOn: Bool, quiet: Bool, interactive: Bool) {
        self.id = id
        self.eventsOn = eventsOn
        self.quiet = quiet
        self.interactive = interactive
        events = CLIEventEmitter(enabled: eventsOn) { printEventLine($0) }
    }

    func start() {
        events.emitStart("Started download of demo project \(id) via lungfish-cli")
    }

    /// One phase of the install. With events on it is a `progress` line, one for each whole percent of
    /// the download and one for each later phase. With events off it is the text the command always
    /// printed.
    func report(_ phase: DemoProjectInstallPhase) {
        state.withLock { $0.reported = true }
        guard eventsOn else {
            guard !quiet else { return }
            DemoCommand.reportProgress(phase, interactive: interactive)
            return
        }
        let line = Self.line(for: phase)
        let fraction: Double? = state.withLock { state in
            if case let .downloading(received, total) = phase {
                let percent = Self.percent(received: received, total: total)
                guard percent != state.lastPercent else { return nil }
                state.lastPercent = percent
            }
            state.highest = max(state.highest, line.fraction)
            return state.highest
        }
        if let fraction { events.emitProgress(fraction, message: line.message) }
    }

    /// The bar's fraction and the words of one phase.
    static func line(for phase: DemoProjectInstallPhase) -> (fraction: Double, message: String) {
        switch phase {
        case let .downloading(received, total):
            var share = 0.0
            if let total, total > 0 { share = min(1, max(0, Double(received) / Double(total))) }
            return (share * downloadShare, detail(for: phase))
        case .verifying:
            return (verifyingFraction, detail(for: phase))
        case .extracting:
            return (extractingFraction, detail(for: phase))
        case .installing:
            return (installingFraction, detail(for: phase))
        }
    }

    /// The same words as `DemoProjectsViewModel.detailText(for:)`, which the window shows.
    static func detail(for phase: DemoProjectInstallPhase) -> String {
        switch phase {
        case let .downloading(received, total):
            let receivedText = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
            if let total, total > 0 {
                return "Downloading \(receivedText) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
            }
            return "Downloading \(receivedText)"
        case .verifying: return "Verifying size and SHA-256…"
        case .extracting: return "Unpacking…"
        case .installing: return "Installing…"
        }
    }

    /// The whole percent of the download, or the whole megabytes when the total is unknown.
    private static func percent(received: Int64, total: Int64?) -> Int {
        if let total, total > 0 { return Int(min(1, max(0, Double(received) / Double(total))) * 100) }
        return Int(received / 1_048_576)
    }

    // MARK: - The end of a run

    /// Prints the end of the run and throws the exit status of a run that did not complete.
    func finish(_ outcome: DemoFetchOutcome) throws {
        if interactive, !quiet, !eventsOn, state.withLock({ $0.reported }) {
            FileHandle.standardError.write(Data("\n".utf8))
        }
        switch outcome {
        case let .installed(title, result):
            if result.replacedPreviousCopy {
                notice("Moved the previous copy to \(result.previousCopyTrashURL?.path ?? "the Trash").")
            }
            complete(result.projectURL, message: "Installed \(title)")
        case let .alreadyInstalled(title, projectURL):
            let message = "\(title) is already installed. Pass --force to replace it with a fresh copy."
            if !eventsOn, !quiet { FileHandle.standardError.write(Data((message + "\n").utf8)) }
            complete(projectURL, message: message)
        case let .failed(error):
            // Text mode lets ArgumentParser print the error as it always did.
            guard eventsOn else { throw error }
            events.emitFailed(error.localizedDescription)
            throw CLIExitCode.failure.exitCode
        case .cancelled:
            events.emitFailed(Self.cancelledMessage)
            if !eventsOn { printStatusLine("Error: \(Self.cancelledMessage)") }
            throw CLIExitCode.cancelled.exitCode
        }
    }

    /// A notice is a `log` line while events are on and a line of standard error otherwise, never both.
    private func notice(_ text: String) {
        if eventsOn {
            events.emitLog(.info, text)
        } else if !quiet {
            FileHandle.standardError.write(Data((text + "\n").utf8))
        }
    }

    private func complete(_ projectURL: URL, message: String) {
        if eventsOn {
            events.emitComplete(outputs: [projectURL.path], artifacts: [], message: message)
        } else {
            Swift.print(projectURL.path)
        }
    }
}

/// One `demo fetch` run. It resolves the project in the list, installs it unless a copy is there, and
/// reports each phase. It never throws. What ended the run is the outcome it returns.
struct DemoFetchRun: Sendable {
    let id: String
    let force: Bool
    let destination: URL
    let manifest: Result<DemoProjectManifest, any Error>
    let reporter: DemoFetchReporter
    /// Moves the old copy of a replace out of the way once the new one has verified. The user's Trash unless
    /// ``trashFolderVariable`` names a folder.
    let trash: DemoProjectInstaller.TrashHandler

    /// The hidden test seam that sends the old copy of a replace into a folder instead of the user's Trash
    /// (Phase 2.10 lane A45 M4), so a test of the replace never writes to the Trash. The item keeps its name in
    /// the folder. It is not in the help.
    static let trashFolderVariable = "LUNGFISH_DEMO_TRASH_FOLDER"

    /// The folder ``trashFolderVariable`` names, nil when it is unset or empty.
    static func trashFolder(environment: [String: String]) -> URL? {
        guard let named = environment[trashFolderVariable], !named.isEmpty else { return nil }
        return URL(fileURLWithPath: (named as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The handler a run uses: the folder's when the variable names one, the user's Trash otherwise.
    static func trashHandler(environment: [String: String]) -> DemoProjectInstaller.TrashHandler {
        guard let folder = trashFolder(environment: environment) else { return DemoProjectInstaller.moveToTrash }
        return { url in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let moved = folder.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            try FileManager.default.moveItem(at: url, to: moved)
            return moved
        }
    }

    func fetch() async -> DemoFetchOutcome {
        do {
            let project = try DemoCommand.resolveProject(id, in: try manifest.get())
            let projectURL = DemoProjectInstaller.projectURL(for: project, in: destination)
            if !force, FileManager.default.fileExists(atPath: projectURL.path) {
                return .alreadyInstalled(title: project.title, projectURL: projectURL)
            }
            let reporter = reporter
            let result = try await DemoProjectInstaller(trash: trash).install(project, into: destination, replaceExisting: force) { phase in
                reporter.report(phase)
            }
            return .installed(title: project.title, result)
        } catch {
            if error is CancellationError || (error as? DemoProjectError) == .cancelled { return .cancelled }
            return .failed(error)
        }
    }
}
