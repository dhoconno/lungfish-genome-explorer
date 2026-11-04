// BlastInFlightMonitor.swift - Finds the BLAST searches that outlived a process and keeps them moving
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow
import os.log

private let monitorLogger = Logger(subsystem: LogSubsystem.app, category: "BlastInFlightMonitor")

/// Keeps a row for each BLAST search that has not ended, and runs one short pass of `lungfish-cli blast resume --once`
/// for each as it falls due (ARCH-BLAST-RESILIENCE item 15 and section 6).
///
/// The app only reads a search's files, and every write stays with the CLI that holds the search's lock. A row waits
/// with no process behind it, so it raises no quit alert and holds no lock. A pass that finds nothing updates its row
/// and logs one line, and only a pass that brings a result back or that NCBI ends leaves the waiting state.
@MainActor
final class BlastInFlightMonitor {
    /// What a pass of `blast resume --once` came to.
    enum PassOutcome: Sendable, Equatable {
        /// The record is saved, with the row's words.
        case collected(outputs: [URL], words: String)
        /// The search still waits, with its row's words.
        case waiting(words: String, state: CLIEventWaitingState)
        /// NCBI or the person ended the search, and these are the words.
        case ended(words: String)
        /// The pass could not tell, so nothing about the search has changed. The words go in the log only.
        case noNews(words: String)
    }

    /// The two things the monitor asks of `lungfish-cli`, apart so that a test can answer them.
    struct Worker: Sendable {
        /// The lines of `blast in-flight --format json`, adopting what `project` holds when one is named.
        var lines: @Sendable (_ project: URL?) async throws -> [BlastInFlightLine]
        /// One pass of `blast resume --output <folder> --once`, with `extra` options after it.
        var pass: @Sendable (_ output: URL, _ extra: [String], _ onEvent: @escaping @Sendable (CLIEvent) -> Void) async -> PassOutcome
        /// A person's Stop.
        var stop: @Sendable (_ output: URL) async -> Void
    }

    /// Posted when a pass has saved a record, with the folder under ``resultFolderKey``.
    static let searchCameBack = Notification.Name("BlastInFlightMonitor.searchCameBack")
    static let resultFolderKey = "resultFolder"
    /// At most this many passes run at a time (section 6).
    static let passesAtATime = 2
    /// A search gets no second pass inside this time, so a pass that could not move its line cannot run in a loop.
    static let leastTimeBetweenPasses: TimeInterval = BlastSearchPolicy.checkFloor
    /// How long a search whose folder has gone rests before its next pass.
    static let folderMissingGap: TimeInterval = 900

    static let shared = BlastInFlightMonitor(worker: .cli())

    private let worker: Worker
    private let center: OperationCenter
    private let now: @Sendable () -> Date
    private var known: [UUID: BlastInFlightLine] = [:]
    private var rows: [UUID: UUID] = [:]
    private var passes: [UUID: Task<Void, Never>] = [:]
    private var lastPassAt: [UUID: Date] = [:]
    private var ended: Set<UUID> = []
    private var timer: Task<Void, Never>?
    private var started = false

    init(worker: Worker, center: OperationCenter = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.worker = worker
        self.center = center
        self.now = now
    }

    // MARK: What starts it

    /// Starts from the app's launch, with no wait on it. Asking twice starts once.
    func start() {
        guard !started else { return }
        started = true
        Task { await self.refresh(project: nil) }
    }

    /// A project has opened, so its searches with no line are adopted (item 18).
    func projectOpened(_ project: URL) {
        Task { await self.refresh(project: project) }
    }

    /// Reads the lines, keeps one row a line, and starts what is due.
    func refresh(project: URL? = nil) async {
        do {
            let lines = try await worker.lines(project)
            for line in lines { take(line) }
            let live = Set(lines.map(\.searchID))
            for searchID in known.keys where !live.contains(searchID) && passes[searchID] == nil { known[searchID] = nil }
        } catch {
            monitorLogger.warning("Could not list the BLAST searches: \(error.localizedDescription, privacy: .public)")
        }
        pump()
    }

    /// Waits for the passes running now, for a test.
    func passesFinished() async {
        while let pass = passes.values.first { await pass.value }
    }

    /// The row of a search, for a test and for the pane.
    func row(ofSearch searchID: UUID) -> UUID? { rows[searchID] }

    // MARK: Rows

    private func take(_ line: BlastInFlightLine) {
        // A line read before its search ended can come after the row has, and it must not begin a second row.
        guard !ended.contains(line.searchID) else { return }
        known[line.searchID] = line
        if let row = rows[line.searchID] {
            if passes[line.searchID] == nil { center.park(id: row, detail: line.words) }
            return
        }
        let output = URL(fileURLWithPath: line.output, isDirectory: true)
        let begun = center.begin(
            title: "BLAST: \(line.label)",
            detail: line.words,
            operationType: .blastVerification,
            startedAt: line.createdAt,
            cliCommand: Self.resumeCommand(output: output),
            onCancel: { [weak self] in
                Task { @MainActor in await self?.stopSearch(line.searchID, output: output) }
            }
        )
        guard case .started(let row) = begun else { return }
        rows[line.searchID] = row
        center.park(id: row, detail: line.words)
    }

    /// The command a parked row records, which goes on with the search (ARCH-BLAST-RESILIENCE section 6).
    nonisolated static func resumeCommand(output: URL) -> String {
        OperationCenter.buildCLICommand(subcommand: "blast resume", args: ["--output", output.path])
    }

    // MARK: Passes

    /// Starts what is due, up to the limit, and sets one timer to the next time anything falls due.
    private func pump() {
        let moment = now()
        let waiting = known.values
            .filter { passes[$0.searchID] == nil && rows[$0.searchID] != nil }
            .compactMap { line in line.nextDueAt.map { (line: line, due: max($0, earliestPass(of: line.searchID))) } }
            .sorted { $0.due < $1.due }
        var startedHere = 0
        for candidate in waiting where candidate.due <= moment {
            guard passes.count < Self.passesAtATime else { break }
            run(pass: candidate.line, extra: [])
            startedHere += 1
        }
        timer?.cancel()
        guard passes.count < Self.passesAtATime, let next = waiting.dropFirst(startedHere).first?.due else { return }
        let delay = max(next.timeIntervalSince(moment), 1)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.pump()
        }
    }

    private func earliestPass(of searchID: UUID) -> Date {
        lastPassAt[searchID]?.addingTimeInterval(Self.leastTimeBetweenPasses) ?? .distantPast
    }

    private func run(pass line: BlastInFlightLine, extra: [String]) {
        guard let row = rows[line.searchID] else { return }
        lastPassAt[line.searchID] = now()
        let output = URL(fileURLWithPath: line.output, isDirectory: true)
        let worker = self.worker
        let onEvent = OperationCenterCLIBridge.onEvent(operationID: row)
        passes[line.searchID] = Task { [weak self] in
            let outcome = await worker.pass(output, extra, onEvent)
            guard let self else { return }
            self.passes[line.searchID] = nil
            self.settle(line, row: row, output: output, outcome: outcome)
            await self.refresh()
        }
    }

    private func settle(_ line: BlastInFlightLine, row: UUID, output: URL, outcome: PassOutcome) {
        switch outcome {
        case .collected(let outputs, let words):
            center.reopen(id: row, detail: words)
            OperationCenterCLIBridge.completeOperation(row, detail: words, outputURLs: outputs)
            forget(line.searchID)
            NotificationCenter.default.post(
                name: Self.searchCameBack, object: self, userInfo: [Self.resultFolderKey: output]
            )
        case .waiting(let words, let state):
            center.park(id: row, detail: words)
            // A folder that has gone comes back when its project opens, which adopts it, so it needs no pass each minute.
            if state == .folderMissing { lastPassAt[line.searchID] = now().addingTimeInterval(Self.folderMissingGap) }
        case .ended(let words):
            center.reopen(id: row, detail: words)
            OperationCenterCLIBridge.failOperation(row, detail: words, fallbackMessage: words)
            forget(line.searchID)
        case .noNews(let words):
            guard !words.isEmpty else { return }
            center.log(id: row, level: .info, message: words)
        }
    }

    private func forget(_ searchID: UUID) {
        ended.insert(searchID)
        known[searchID] = nil
        rows[searchID] = nil
        lastPassAt[searchID] = nil
    }

    /// A row's Cancel, which does what the pane's Stop does (UX-BLAST-WORDS Q3).
    private func stopSearch(_ searchID: UUID, output: URL) async {
        let row = rows[searchID]
        await worker.stop(output)
        passes[searchID]?.cancel()
        forget(searchID)
        guard let row else { return }
        center.acknowledgeCancellation(id: row)
        center.setStoppedWords(id: row, words: BlastSearchWords.stopped)
    }
}

// MARK: - The worker on lungfish-cli

extension BlastInFlightMonitor.Worker {
    /// What `blast in-flight --format json` prints.
    private struct Document: Decodable {
        var lines: [BlastInFlightLine]
    }

    /// A pass that runs longer than this is ended, which ends the process and never the search (section 4).
    static let passWatchdog: Duration = .seconds(600)

    /// The worker that runs `lungfish-cli`. A pass runs as a child, so that a project folder that hangs never holds up the app.
    static func cli(cliURLOverride: URL? = nil, environmentAdditions: [String: String] = [:]) -> BlastInFlightMonitor.Worker {
        BlastInFlightMonitor.Worker(
            lines: { project in
                let transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
                var arguments = ["blast", "in-flight", "--format", "json"]
                if let project { arguments += ["--project", project.path] }
                let data = try await transport.runForOutput(arguments: arguments, environmentAdditions: environmentAdditions)
                return try BlastSubmissionRecord.decoder.decode(Document.self, from: data).lines
            },
            pass: { output, extra, onEvent in
                let transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
                let watchdog = Task {
                    try await Task.sleep(for: passWatchdog)
                    transport.cancel()
                }
                defer { watchdog.cancel() }
                do {
                    let result = try await transport.run(
                        arguments: ["blast", "resume", "--output", output.path, "--once"] + extra + ["--format", "json", "--no-progress"],
                        terminationGracePeriod: CLIProcessLauncher.operationGrace,
                        drainGracePeriod: CLIProcessLauncher.operationDrain,
                        environmentAdditions: environmentAdditions,
                        isCancelled: { false },
                        onEvent: onEvent
                    )
                    if let waiting = result.waiting { return .waiting(words: waiting.message, state: waiting.state) }
                    return .collected(outputs: result.outputs.map { URL(fileURLWithPath: $0) }, words: result.message ?? "")
                } catch CLISubprocessTransport.RunError.failedEvent(let message, _) {
                    // A failed event from a search that goes on, such as a reply that cannot be read, is not an ending.
                    let ended = (try? BlastSearchStore(folder: output).load())?.state.isEnding ?? false
                    return ended ? .ended(words: message) : .waiting(words: message, state: .parked)
                } catch is CancellationError {
                    return .noNews(words: "")
                } catch {
                    return .noNews(words: error.localizedDescription)
                }
            },
            stop: { output in
                let transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
                do {
                    _ = try await transport.run(
                        arguments: ["blast", "stop", "--output", output.path, "--format", "json", "--no-progress"],
                        environmentAdditions: environmentAdditions,
                        isCancelled: { false },
                        onEvent: { _ in }
                    )
                } catch {
                    monitorLogger.warning("Could not stop a BLAST search: \(error.localizedDescription, privacy: .public)")
                }
            }
        )
    }
}
