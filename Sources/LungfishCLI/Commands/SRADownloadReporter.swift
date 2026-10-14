// SRADownloadReporter.swift - The events and human text of lungfish-cli fetch sra download
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow
import os

/// Writes what `fetch sra download` prints (Phase 2.10 lane A45 M3, ruling A45-M3 section 1).
///
/// With `--format json` a run is one `start` line, `progress` lines, `log` lines for a fallback to
/// the other archive and for a layout warning, and one `complete` line or one `failed` line. The
/// human text goes to standard error. With events off the human text stays on standard output, as it
/// always was. A plain run's `complete` names the FASTQ files. With `--bundle` the download takes the
/// first ``downloadShare`` of the bar and the import the rest up to ``importEnd``, so the child's
/// events are its own and the import's events never reach standard output (the manager's answer on
/// the nested child). The `complete` line names the published bundle with one artifact of the FASTQ
/// bundle kind and its record.
final class SRADownloadReporter: FASTQImportReporting, Sendable {
    let eventsOn: Bool
    private let quiet: Bool
    private let useColors: Bool
    private let accession: String
    private let downloadShare: Double
    private let events: CLIEventEmitter
    private let stream: OSAllocatedUnfairLock<FASTQImportEventStream>

    private var formatter: TerminalFormatter { TerminalFormatter(useColors: useColors) }

    /// Where the import's share of the bar ends, before the bundle is published.
    static let importEnd = 0.95

    init(accession: String, eventsOn: Bool, quiet: Bool, useColors: Bool, downloadShare: Double, projectDirectory: URL) {
        self.accession = accession
        self.eventsOn = eventsOn
        self.quiet = quiet
        self.useColors = useColors
        self.downloadShare = downloadShare
        events = CLIEventEmitter(enabled: eventsOn) { printEventLine($0) }
        stream = OSAllocatedUnfairLock(initialState: FASTQImportEventStream(projectDirectory: projectDirectory))
    }

    func start() {
        events.emitStart("Started SRA download of \(accession) via lungfish-cli")
    }

    /// One line of human text, dropped by `--quiet`.
    func text(_ line: String) {
        guard !quiet else { return }
        printHumanLine(line, eventsOn: eventsOn)
    }

    func info(_ line: String) { text(formatter.info(line)) }

    /// A download share of `fraction`, 0 to 1, as the bar and as the line `fetch sra download` always printed.
    func downloadProgress(_ fraction: Double) {
        events.emitProgress(min(max(fraction, 0), 1) * downloadShare, message: "Downloading \(accession)")
        info("Download progress: \(Int(fraction * 100))%")
    }

    /// The line a fallback to the other archive logs.
    func fallback(_ message: String) {
        events.emitLog(.warning, message)
        info(message)
    }

    /// The layout warning of a run whose files arrived in a shape its archive record does not list.
    func layoutWarning(_ message: String) {
        events.emitLog(.warning, message)
        text(formatter.warning(message))
    }

    /// The verbatim standard error of a failed SRA Toolkit step, under `--verbose`.
    func toolOutput(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// The bar for the stage after the download, where `fraction` is the stage's own 0 to 1.
    func stageProgress(_ fraction: Double, message: String) {
        let width = Self.importEnd - downloadShare
        events.emitProgress(downloadShare + min(max(fraction, 0), 1) * width, message: message)
    }

    // MARK: - FASTQImportReporting

    func pairingNotice(sample: String, message: String) {
        events.emitLog(.warning, "\(sample): \(message)")
        text(formatter.warning("\(sample): \(message)"))
    }

    /// One log event of the import, mapped onto this command's own progress and log lines.
    func log(_ event: ImportLogEvent) {
        guard eventsOn else {
            if case let .platformResolved(sample, _, _, _, _, _, message) = event { info("\(sample): \(message)") }
            return
        }
        let lines = stream.withLock { $0.events(for: event) }
        for line in lines {
            switch line {
            case let .progress(fraction, message): stageProgress(fraction, message: message)
            case let .log(level, message): events.emitLog(level, message)
            default: break
            }
        }
    }

    /// The words of the `failed` line of a run a cancel ended, which the app reads as Cancelled.
    static let cancelledMessage = "Fetch cancelled"

    func fail(_ message: String, detail: String?, exitCode: CLIExitCode) -> ExitCode {
        // A cancel reads the same whichever stage noticed it, so the import's own words give way.
        let message = exitCode == .cancelled ? Self.cancelledMessage : message
        text(formatter.error(message))
        events.emitFailed(message, detail: detail)
        return exitCode.exitCode
    }

    func failedEvent(_ message: String) {
        events.emitFailed(message)
    }

    // MARK: - The end of a run

    /// The end of a plain run, which names the FASTQ files it downloaded.
    func completePlain(files: [URL]) {
        events.emitComplete(outputs: files.map(\.path), artifacts: [], message: "Downloaded \(files.count) FASTQ file(s)")
        if !eventsOn, !quiet {
            print(formatter.success("Downloaded \(files.count) FASTQ file(s):"))
            for file in files {
                print("  - \(file.lastPathComponent)")
            }
        }
    }

    /// The end of a `--bundle` run, which names the bundle it published and its record.
    func completeBundle(_ bundle: URL, record: URL?) {
        let artifact = CLIEventArtifact(
            kind: BundleKindID.fastq.rawValue, path: bundle.path, role: CLIEventArtifact.Role.bundle,
            provenancePath: record?.path
        )
        events.emitComplete(outputs: [bundle.path], artifacts: [artifact], message: "Imported \(accession)")
        text(formatter.success("Imported \(accession): \(bundle.path)"))
    }

    /// Ends a run that failed after its human text was printed or that has none, with the failed line.
    func failedRun(_ message: String) {
        events.emitFailed(message)
        if !eventsOn { printStatusLine("Error: \(message)") }
    }
}
