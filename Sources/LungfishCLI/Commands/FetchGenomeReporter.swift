// FetchGenomeReporter.swift - The events and human text of lungfish-cli fetch genome
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

/// What one `fetch genome` run made for one accession.
enum FetchGenomeOutput: Sendable {
    /// A bundle and its provenance record, when the run wrote one.
    case bundle(URL, record: URL?)
    /// The files of `--fasta-only` or `--no-bundle`.
    case files([URL])

    var paths: [String] {
        switch self {
        case let .bundle(url, _): return [url.path]
        case let .files(urls): return urls.map(\.path)
        }
    }
}

/// How a `fetch genome` run ended.
struct FetchGenomeOutcome: Sendable {
    struct Failure: Sendable {
        let accession: String
        let message: String

        var line: String { accession.isEmpty ? message : "\(accession): \(message)" }
    }

    var outputs: [FetchGenomeOutput] = []
    var failures: [Failure] = []
    var cancelled = false
}

/// Writes the events and the human text of `fetch genome` (Phase 2.10 lane A44).
///
/// With `--format json` a run is one `start` line, `progress` lines whose fraction is
/// `(index + share) / count` for accession `index` of `count`, `log` lines, and one `complete` line
/// that names each bundle in `outputs` with one artifact of kind `reference` and role `bundle`, or
/// one `failed` line. A run goes on past an accession that fails and ends `failed` with the last
/// failure as `<accession>: <error>` and every failure in `detail` when there are several. A
/// cancelled run ends `failed` with `Fetch cancelled` and exits 125. The human text goes to standard
/// error while events are on. With events off the warnings and the failure go to standard error, and
/// `--quiet` drops everything but the failure.
struct FetchGenomeReporter: Sendable {
    let eventsOn: Bool
    let quiet: Bool
    let useColors: Bool
    /// What one accession becomes, in the words of the start, heading and closing lines. `fetch
    /// ncbi --bundle` (lane A45) passes `NCBI bundle` and shares the rest of the reporter.
    let subject: String
    private let events: CLIEventEmitter

    init(eventsOn: Bool, quiet: Bool, useColors: Bool, subject: String = "genome") {
        self.eventsOn = eventsOn
        self.quiet = quiet
        self.useColors = useColors
        self.subject = subject
        events = CLIEventEmitter(enabled: eventsOn) { printEventLine($0) }
    }

    private var formatter: TerminalFormatter { TerminalFormatter(useColors: useColors) }

    func start(accessions: [String]) {
        events.emitStart("Started \(subject) fetch of \(accessions.count) accession(s) via lungfish-cli")
    }

    func text(_ line: String) {
        guard !quiet else { return }
        printHumanLine(line, eventsOn: eventsOn)
    }

    func info(_ line: String) { text(formatter.info(line)) }

    func success(_ line: String) { text(formatter.success(line)) }

    func header(_ line: String) { text(formatter.header(line)) }

    func warning(_ message: String) {
        events.emitLog(.warning, message)
        if !eventsOn, !quiet {
            printStatusLine(formatter.warning(message))
        }
    }

    /// The handler a builder reports its share of accession `index` of `count` through.
    func progressHandler(accession: String, index: Int, count: Int) -> @Sendable (Double, String) -> Void {
        let reporter = self
        return { share, message in
            let fraction = (Double(index) + min(max(share, 0), 1)) / Double(max(count, 1))
            reporter.progress(fraction, message: "\(accession): \(message)", share: share)
        }
    }

    private func progress(_ fraction: Double, message: String, share: Double) {
        if eventsOn {
            events.emitProgress(fraction, message: message)
        } else if !quiet {
            print("\r  [\(Int(share * 100))%] \(message)", terminator: "")
            fflush(stdout)
        }
    }

    func beginAccession(_ accession: String, index: Int, count: Int, destination: URL) {
        header("Fetching \(subject.prefix(1).uppercased() + subject.dropFirst()) \(index + 1) of \(count)")
        text("Accession: \(accession)")
        text("Output: \(destination.path)")
        text("")
    }

    func finishedAccession(_ output: FetchGenomeOutput) {
        if !eventsOn, !quiet { print("") }
        for path in output.paths {
            success("Saved: \(path)")
        }
    }

    func failedAccession(_ failure: FetchGenomeOutcome.Failure) {
        if !eventsOn, !quiet { print("") }
        events.emitLog(.error, failure.line)
        if !eventsOn, !quiet {
            printStatusLine(formatter.error(failure.line))
        }
    }

    /// Prints the end of the run and throws the exit status of a run that did not complete.
    func finish(_ outcome: FetchGenomeOutcome) throws {
        if outcome.cancelled {
            fail("Fetch cancelled", detail: nil)
            throw CLIExitCode.cancelled.exitCode
        }
        if let last = outcome.failures.last {
            let detail = outcome.failures.count > 1 ? outcome.failures.map(\.line).joined(separator: "\n") : nil
            fail(last.line, detail: detail)
            throw CLIExitCode.failure.exitCode
        }
        var artifacts: [CLIEventArtifact] = []
        for case let .bundle(url, record) in outcome.outputs {
            artifacts.append(CLIEventArtifact(
                kind: BundleKindID.reference.rawValue,
                path: url.path,
                role: "bundle",
                provenancePath: record?.path
            ))
        }
        let paths = outcome.outputs.flatMap(\.paths)
        events.emitComplete(outputs: paths, artifacts: artifacts, message: "Fetched \(outcome.outputs.count) \(subject)(s)")
        text("")
        success("Fetched \(outcome.outputs.count) \(subject)(s)")
    }

    private func fail(_ message: String, detail: String?) {
        events.emitFailed(message, detail: detail)
        if !eventsOn {
            printStatusLine("Error: \(message)")
        }
    }
}
