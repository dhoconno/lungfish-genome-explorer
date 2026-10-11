// CLISubprocessTransportTests.swift - lungfish-cli runs on ToolProcess, so output never deadlocks and a cancel stops the tree
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishKit
import LungfishWorkflow

/// Phase 2.2 lane 3A (finding R7). The transport used to read the pipes with
/// readability handlers, and read to end of file after the process exited. It
/// now runs on ToolProcess. Each test runs a shell script in place of
/// `lungfish-cli`.
final class CLISubprocessTransportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "cli-transport")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(folder)
    }

    private func fakeCLI(_ script: String) throws -> URL {
        let url = folder.appendingPathComponent("lungfish-cli")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func completeLine(outputs: [String]) throws -> String {
        let data = try JSONEncoder().encode(CLIEvent.complete(outputs: outputs, message: "done"))
        return String(decoding: data, as: UTF8.self)
    }

    private func wait(
        for task: Task<CLISubprocessTransport.Result, Error>,
        timeout: Duration = .seconds(30)
    ) async throws -> Swift.Result<CLISubprocessTransport.Result, Error> {
        let box = ResultBox()
        let waiter = Task {
            let outcome: Swift.Result<CLISubprocessTransport.Result, Error>
            do { outcome = .success(try await task.value) } catch { outcome = .failure(error) }
            box.set(outcome)
        }
        defer { waiter.cancel() }
        let finished = await waitUntil(timeout: timeout) { box.value != nil }
        XCTAssertTrue(finished, "the run did not finish, so it is blocked")
        return try XCTUnwrap(box.value)
    }

    /// More than the 64 KB a pipe holds on both streams, with the process
    /// writing stderr first. A transport that does not read both streams
    /// from launch stalls the CLI and never returns.
    func testOutputOver64KBOnBothStreamsDoesNotDeadlock() async throws {
        let complete = try completeLine(outputs: ["/tmp/result"])
        let cli = try fakeCLI("""
        #!/bin/sh
        /usr/bin/head -c 300000 /dev/zero | /usr/bin/tr '\\0' 'e' >&2
        echo >&2
        echo '{"event":"progress","progress":0.5,"message":"halfway"}'
        /usr/bin/head -c 300000 /dev/zero | /usr/bin/tr '\\0' 'o'
        echo
        echo '\(complete)'
        """)
        let events = EventLog()
        let transport = CLISubprocessTransport(cliURLOverride: cli)
        let task = Task {
            try await transport.run(arguments: [], isCancelled: { false }, onEvent: { events.append($0) })
        }
        let outcome = try await wait(for: task)
        let result = try outcome.get()
        XCTAssertEqual(result.outputs, ["/tmp/result"])
        XCTAssertEqual(result.message, "done")
        // The two streams are read side by side, so their lines may interleave
        // either way. Standard error arrives as an info log line.
        XCTAssertEqual(events.values.count, 2)
        XCTAssertTrue(events.values.contains(.progress(fraction: 0.5, message: "halfway")))
        XCTAssertTrue(events.values.contains(.log(level: .info, message: String(repeating: "e", count: 300_000))))
    }

    /// The failure message carries the whole of a stderr over 64 KB.
    func testANonZeroExitCarriesAllOfALargeStderr() async throws {
        let cli = try fakeCLI("""
        #!/bin/sh
        /usr/bin/head -c 200000 /dev/zero | /usr/bin/tr '\\0' 'e' >&2
        echo >&2
        /usr/bin/head -c 200000 /dev/zero | /usr/bin/tr '\\0' 'o'
        exit 7
        """)
        let transport = CLISubprocessTransport(cliURLOverride: cli)
        let task = Task {
            try await transport.run(arguments: [], isCancelled: { false }, onEvent: { _ in })
        }
        let outcome = try await wait(for: task)
        guard case .failure(let error) = outcome,
              case CLISubprocessTransport.RunError.nonZeroExit(let status, let stderr) = error else {
            return XCTFail("expected a nonZeroExit, got \(outcome)")
        }
        XCTAssertEqual(status, 7)
        XCTAssertEqual(stderr.trimmingCharacters(in: .whitespacesAndNewlines).count, 200_000)
    }

    /// ToolProcess hands a long line over in pieces of at most 64 KB. An event
    /// line longer than that, such as a `complete` that lists thousands of
    /// outputs, is still decoded whole.
    func testAnEventLineLongerThan64KBIsDecodedWhole() async throws {
        let outputs = (0..<3_000).map { "/tmp/results/sample-\($0)/aligned-reads.sorted.bam" }
        let line = try completeLine(outputs: outputs)
        XCTAssertGreaterThan(line.utf8.count, 128 * 1024)
        let lineFile = folder.appendingPathComponent("complete.json")
        try line.write(to: lineFile, atomically: true, encoding: .utf8)
        let cli = try fakeCLI("""
        #!/bin/sh
        echo '{"event":"progress","progress":0.1,"message":"first"}'
        /bin/cat '\(lineFile.path)'
        echo
        """)
        let events = EventLog()
        let transport = CLISubprocessTransport(cliURLOverride: cli)
        let task = Task {
            try await transport.run(arguments: [], isCancelled: { false }, onEvent: { events.append($0) })
        }
        let result = try await wait(for: task).get()
        XCTAssertEqual(result.outputs, outputs)
        XCTAssertEqual(events.values, [.progress(fraction: 0.1, message: "first")])
    }

    func testEventsArriveInOrder() async throws {
        let lines = (1...40).map { #"echo '{"event":"progress","progress":\#(Double($0) / 40),"message":"step \#($0)"}'"# }
        let complete = try completeLine(outputs: ["/tmp/out"])
        let cli = try fakeCLI("#!/bin/sh\n" + lines.joined(separator: "\n") + "\necho '\(complete)'\n")
        let events = EventLog()
        let transport = CLISubprocessTransport(cliURLOverride: cli)
        let task = Task {
            try await transport.run(arguments: [], isCancelled: { false }, onEvent: { events.append($0) })
        }
        _ = try await wait(for: task).get()
        let messages = events.values.compactMap { event -> String? in
            if case .progress(_, let message) = event { return message }
            return nil
        }
        XCTAssertEqual(messages, (1...40).map { "step \($0)" })
    }

    func testAFailedEventIsDeliveredAndThrown() async throws {
        let cli = try fakeCLI("""
        #!/bin/sh
        echo '{"event":"failed","error":"no good","detail":"because"}'
        exit 3
        """)
        let events = EventLog()
        let transport = CLISubprocessTransport(cliURLOverride: cli)
        let task = Task {
            try await transport.run(arguments: [], isCancelled: { false }, onEvent: { events.append($0) })
        }
        let outcome = try await wait(for: task)
        guard case .failure(let error) = outcome,
              case CLISubprocessTransport.RunError.failedEvent(let message, let detail) = error else {
            return XCTFail("expected a failedEvent, got \(outcome)")
        }
        XCTAssertEqual(message, "no good")
        XCTAssertEqual(detail, "because")
        XCTAssertEqual(events.values, [.failed(message: "no good", detail: "because")])
    }

    // MARK: - Event lines of any version (Phase 2.6 lane C3)

    /// A stand-in CLI that prints `lines` on standard output and exits with `status`.
    /// The lines go through a file, so the shell never reads their backslashes.
    private func fakeCLI(printing lines: [String], exitStatus: Int32 = 0) throws -> URL {
        let transcript = folder.appendingPathComponent("stdout-\(UUID().uuidString).ndjson")
        try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        return try fakeCLI("#!/bin/sh\n/bin/cat '\(transcript.path)'\nexit \(exitStatus)\n")
    }

    private func run(_ cli: URL, events: EventLog = EventLog()) async throws -> Swift.Result<CLISubprocessTransport.Result, Error> {
        let transport = CLISubprocessTransport(cliURLOverride: cli)
        let task = Task {
            try await transport.run(arguments: [], isCancelled: { false }, onEvent: { events.append($0) })
        }
        return try await wait(for: task)
    }

    /// The typed artifacts of the completion come back beside `outputs`, which keeps
    /// its own order. A kind that names a registered bundle kind reads as that kind
    /// when the path carries the kind's folder extension, so a FASTQ file is not read
    /// as a FASTQ bundle, and every kind stays the string the CLI wrote.
    func testTypedArtifactsOfTheCompletionComeBackBesideItsOutputs() async throws {
        let complete = """
        {"artifacts":[{"kind":"phylogenetic-tree","path":"/work/t.lungfishtree","role":"tree"},\
        {"kind":"bam","path":"/work/a.bam","provenancePath":"/work/a.provenance.json","role":"alignment"},\
        {"kind":"holographic-bundle","path":"/work/h","sizeBytes":12},\
        {"kind":"fastq","path":"/work/reads.fastq.gz","role":"reads"},\
        {"kind":"fastq","path":"/work/S.lungfishfastq","role":"reads"}],\
        "event":"complete","message":"done","outputs":["/work/a.bam","/work/t.lungfishtree"],"schemaVersion":2}
        """
        let result = try await run(try fakeCLI(printing: [complete])).get()

        XCTAssertEqual(result.outputs, ["/work/a.bam", "/work/t.lungfishtree"])
        XCTAssertEqual(result.message, "done")
        XCTAssertEqual(result.artifacts, [
            CLIEventArtifact(kind: "phylogenetic-tree", path: "/work/t.lungfishtree", role: "tree"),
            CLIEventArtifact(kind: "bam", path: "/work/a.bam", role: "alignment", provenancePath: "/work/a.provenance.json"),
            CLIEventArtifact(kind: "holographic-bundle", path: "/work/h"),
            CLIEventArtifact(kind: "fastq", path: "/work/reads.fastq.gz", role: "reads"),
            CLIEventArtifact(kind: "fastq", path: "/work/S.lungfishfastq", role: "reads"),
        ])
        XCTAssertEqual(result.artifacts.map(\.bundleKind), [.phylogeneticTree, nil, nil, nil, .fastq])
        XCTAssertEqual(result.artifacts.map(\.kind), ["phylogenetic-tree", "bam", "holographic-bundle", "fastq", "fastq"])
    }

    /// A version 1 completion carries no artifacts.
    func testAVersion1CompletionComesBackWithNoArtifacts() async throws {
        let result = try await run(try fakeCLI(printing: [
            #"{"event":"complete","output":"\/work\/a.fa","outputs":["\/work\/a.fa"],"progress":1}"#,
        ])).get()

        XCTAssertEqual(result.outputs, ["/work/a.fa"])
        XCTAssertEqual(result.artifacts, [])
    }

    /// A line whose event this reader does not know, and a known event from a later
    /// version whose fields it cannot read, are skipped, and the run goes on.
    func testALineFromALaterCLIIsSkippedAndTheRunGoesOn() async throws {
        let events = EventLog()
        let result = try await run(try fakeCLI(printing: [
            #"{"event":"start","message":"Starting.","progress":0,"schemaVersion":2}"#,
            #"{"event":"checkpoint","schemaVersion":3,"step":4,"artifacts":[{"kind":"k","path":"\/work\/x"}]}"#,
            #"{"event":"progress","progress":"half","schemaVersion":3}"#,
            #"{"event":"progress","message":"halfway","progress":0.5,"schemaVersion":3,"eta":12}"#,
            #"{"event":"complete","outputs":["\/work\/a.fa"],"schemaVersion":3,"checksum":"abc"}"#,
        ]), events: events).get()

        XCTAssertEqual(events.values, [.start(message: "Starting."), .progress(fraction: 0.5, message: "halfway")])
        XCTAssertEqual(result.outputs, ["/work/a.fa"])
    }

    /// A known event with unreadable fields at a version this reader knows is a
    /// broken line. It is logged and skipped, and the run goes on.
    func testABrokenLineIsSkippedAndTheRunGoesOn() async throws {
        let events = EventLog()
        let result = try await run(try fakeCLI(printing: [
            #"{"event":"progress","progress":"half","schemaVersion":2}"#,
            #"{"event":"progress","progress":0.5,"message":"halfway"}"#,
            #"{"event":"complete","outputs":["\/work\/a.fa"],"schemaVersion":2}"#,
        ]), events: events).get()

        XCTAssertEqual(events.values, [.progress(fraction: 0.5, message: "halfway")])
        XCTAssertEqual(result.outputs, ["/work/a.fa"])
    }

    /// Plain standard error is human text. Each line that is not blank reaches
    /// `onEvent` as an info log line, in its own order, so the operation log keeps it
    /// at info level even when it says "warning".
    func testPlainStandardErrorArrivesAsInfoLogLines() async throws {
        let stdoutLines = folder.appendingPathComponent("stdout.ndjson")
        let stderrLines = folder.appendingPathComponent("stderr.txt")
        try """
        {"event":"progress","message":"halfway","progress":0.5,"schemaVersion":2}
        {"event":"complete","outputs":["/work/a.fa"],"schemaVersion":2}

        """.write(to: stdoutLines, atomically: true, encoding: .utf8)
        try "Reading the input bundle.\n\n   \nwarning: this text is not a warning event\n"
            .write(to: stderrLines, atomically: true, encoding: .utf8)
        let cli = try fakeCLI("#!/bin/sh\n/bin/cat '\(stderrLines.path)' >&2\n/bin/cat '\(stdoutLines.path)'\n")

        let events = EventLog()
        let result = try await run(cli, events: events).get()

        let logLines = events.values.filter { if case .log = $0 { return true } else { return false } }
        XCTAssertEqual(logLines, [
            .log(level: .info, message: "Reading the input bundle."),
            .log(level: .info, message: "warning: this text is not a warning event"),
        ])
        XCTAssertTrue(events.values.contains(.progress(fraction: 0.5, message: "halfway")))
        XCTAssertEqual(events.values.count, 3)
        XCTAssertEqual(result.outputs, ["/work/a.fa"])
    }

    /// Artifacts never stand in for outputs, so a completion that names no output
    /// still fails the run.
    func testACompletionThatNamesNoOutputFailsEvenWithArtifacts() async throws {
        let outcome = try await run(try fakeCLI(printing: [
            #"{"artifacts":[{"kind":"bam","path":"\/work\/a.bam"}],"event":"complete","outputs":[],"schemaVersion":2}"#,
        ]))

        guard case .failure(let error) = outcome,
              case CLISubprocessTransport.RunError.missingCompletion = error else {
            return XCTFail("expected missingCompletion, got \(outcome)")
        }
    }

    /// Every version 1 run captured from a real command, and the same run written as
    /// version 2 lines with artifacts on its completion, give the same events,
    /// outcome and `outputs`.
    func testEveryCapturedRunGivesTheSameOutcomeAsVersion1AndVersion2() async throws {
        let decoder = CLIEventLineDecoder()
        for name in CLIEventCompatCorpus.capturedRuns {
            let url = CLIEventCompatCorpus.v1Folder.appendingPathComponent("\(name).ndjson")
            let version1 = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            var version2: [String] = []
            var addedArtifacts: [CLIEventArtifact] = []
            let emitter = CLIEventEmitter(enabled: true) { version2.append($0) }
            for line in version1 {
                let event = try XCTUnwrap(try decoder.decode(line: line), "\(name): \(line)")
                if case let .complete(outputs, _) = event {
                    addedArtifacts = outputs.map { CLIEventArtifact(kind: "kind-from-a-later-registry", path: $0, role: "primary") }
                }
                emitter.emit(event, artifacts: addedArtifacts)
            }
            XCTAssertTrue(version2.allSatisfy { $0.contains(#""schemaVersion":2"#) }, name)
            let status: Int32 = name.hasSuffix("-failed") ? 1 : 0

            let events1 = EventLog()
            let events2 = EventLog()
            let outcome1 = try await run(try fakeCLI(printing: version1, exitStatus: status), events: events1)
            let outcome2 = try await run(try fakeCLI(printing: version2, exitStatus: status), events: events2)

            XCTAssertEqual(events2.values, events1.values, name)
            switch (outcome1, outcome2) {
            case let (.success(result1), .success(result2)):
                XCTAssertEqual(result2.outputs, result1.outputs, name)
                XCTAssertEqual(result2.message, result1.message, name)
                XCTAssertEqual(result1.artifacts, [], name)
                XCTAssertEqual(result2.artifacts, addedArtifacts, name)
            case let (.failure(error1), .failure(error2)):
                XCTAssertEqual(error2 as? CLISubprocessTransport.RunError, error1 as? CLISubprocessTransport.RunError, name)
                guard case CLISubprocessTransport.RunError.failedEvent = error1 else {
                    return XCTFail("\(name) must fail with its failed event, got \(error1)")
                }
            default:
                XCTFail("\(name) ended differently: \(outcome1) against \(outcome2)")
            }
        }
    }

    func testAnUnlaunchableBinaryThrowsLaunchFailed() async throws {
        let transport = CLISubprocessTransport(cliURLOverride: folder)
        let task = Task {
            try await transport.run(arguments: [], isCancelled: { false }, onEvent: { _ in })
        }
        let outcome = try await wait(for: task)
        guard case .failure(let error) = outcome, case CLISubprocessTransport.RunError.launchFailed = error else {
            return XCTFail("expected launchFailed, got \(outcome)")
        }
    }

    /// A cancel kills the CLI's own child, which a process that was only
    /// signaled at its root would leave running.
    func testCancelKillsAGrandchildOfTheCLI() async throws {
        let grandchildPIDFile = folder.appendingPathComponent("grandchild.pid")
        let cli = try fakeCLI("""
        #!/bin/sh
        /bin/sh -c 'echo $$ > "\(grandchildPIDFile.path)"; trap "" TERM; while true; do /bin/sleep 1; done' &
        echo '{"event":"progress","progress":0.1,"message":"started"}'
        wait
        """)
        let transport = CLISubprocessTransport(cliURLOverride: cli)
        let task = Task {
            try await transport.run(arguments: [], isCancelled: { false }, onEvent: { _ in })
        }
        var grandchild: Int32?
        let started = await waitUntil(timeout: .seconds(30)) {
            grandchild = (try? String(contentsOf: grandchildPIDFile, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return grandchild != nil
        }
        XCTAssertTrue(started)
        let pid = try XCTUnwrap(grandchild)
        defer { kill(pid, SIGKILL) }
        XCTAssertTrue(ProcessTreeTerminator.processExists(pid: pid))

        let clock = ContinuousClock()
        let start = clock.now
        transport.cancel()
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1), "cancel returns at once")

        let outcome = try await wait(for: task)
        guard case .failure(let error) = outcome else { return XCTFail("a cancelled run returns no result") }
        XCTAssertTrue(error is CancellationError, "\(error)")
        let gone = await waitUntil(timeout: .seconds(30)) { !ProcessTreeTerminator.processExists(pid: pid) }
        XCTAssertTrue(gone, "the grandchild is stopped, even though it ignores SIGTERM")
    }

    func testACancelBeforeTheRunNeverLaunchesTheCLI() async throws {
        let marker = folder.appendingPathComponent("launched")
        let cli = try fakeCLI("""
        #!/bin/sh
        touch '\(marker.path)'
        """)
        let transport = CLISubprocessTransport(cliURLOverride: cli)
        transport.cancel()
        let task = Task {
            try await transport.run(arguments: [], isCancelled: { false }, onEvent: { _ in })
        }
        let outcome = try await wait(for: task)
        guard case .failure(let error) = outcome else { return XCTFail("a cancelled run returns no result") }
        XCTAssertTrue(error is CancellationError, "\(error)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCancellingTheTaskStopsTheCLI() async throws {
        let pidFile = folder.appendingPathComponent("cli.pid")
        let cli = try fakeCLI("""
        #!/bin/sh
        echo $$ > '\(pidFile.path)'
        while true; do /bin/sleep 1; done
        """)
        let transport = CLISubprocessTransport(cliURLOverride: cli)
        let task = Task {
            try await transport.run(arguments: [], isCancelled: { false }, onEvent: { _ in })
        }
        var cliPID: Int32?
        let started = await waitUntil(timeout: .seconds(30)) {
            cliPID = (try? String(contentsOf: pidFile, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return cliPID != nil
        }
        XCTAssertTrue(started)
        let pid = try XCTUnwrap(cliPID)
        defer { kill(pid, SIGKILL) }
        task.cancel()
        let outcome = try await wait(for: task)
        guard case .failure(let error) = outcome else { return XCTFail("a cancelled run returns no result") }
        XCTAssertTrue(error is CancellationError, "\(error)")
        let gone = await waitUntil(timeout: .seconds(30)) { !ProcessTreeTerminator.processExists(pid: pid) }
        XCTAssertTrue(gone)
    }

    // MARK: - Cancel grace (Phase 2.7 lane S0, panel decision E5)

    /// Makes a FIFO that no one writes to. A stand-in CLI opens it for reading and
    /// writing and waits on it with the shell's own `read -t`, which starts no
    /// child process. The terminator signals every descendant it finds, so a
    /// stand-in that waited with `sleep` would be woken early by that signal.
    private func makeHold() -> URL {
        let hold = folder.appendingPathComponent("hold.fifo")
        XCTAssertEqual(mkfifo(hold.path, 0o600), 0, "mkfifo failed")
        return hold
    }

    /// A stand-in CLI that cleans up on SIGTERM the way a command under
    /// `SIGTERMCancellation` does. Its handler works for `cleanupSeconds`, then
    /// writes `marker` and exits by itself. `started` appears once the handler is
    /// in place.
    private func cleaningCLI(cleanupSeconds: Int, hold: URL, started: URL, marker: URL) throws -> URL {
        try fakeCLI("""
        #!/bin/bash
        exec 3<> "\(hold.path)"
        trap 'read -t \(cleanupSeconds) -u 3 line; echo cleaned > "\(marker.path)"; exit 0' TERM
        echo started > "\(started.path)"
        while true; do read -t 1 -u 3 line; done
        """)
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func readPID(_ url: URL) -> Int32? {
        (try? String(contentsOf: url, encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Starts `run` on a transport over `cli`, cancels it once `started` exists and
    /// returns how long the run took to end after the cancel. The run must end with
    /// a `CancellationError`.
    private func cancelOnceStarted(
        _ cli: URL,
        started: URL,
        run: @escaping @Sendable (CLISubprocessTransport) async throws -> CLISubprocessTransport.Result
    ) async throws -> Duration {
        let transport = CLISubprocessTransport(cliURLOverride: cli)
        let task = Task { try await run(transport) }
        let up = await waitUntil(timeout: .seconds(30)) { fileExists(started) }
        XCTAssertTrue(up, "the stand-in CLI never started")
        let clock = ContinuousClock()
        let start = clock.now
        transport.cancel()
        let outcome = try await wait(for: task)
        switch outcome {
        case .success:
            XCTFail("a cancelled run returns no result")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        return start.duration(to: clock.now)
    }

    /// A cancel sends SIGTERM, and the CLI has `terminationGracePeriod` to clean up
    /// before SIGKILL. Here the cleanup takes two seconds, and the run ends when the
    /// CLI exits by itself, long before the 60 second deadline (`wait(for:)` fails the
    /// test after 30 seconds, so a run that waited for the deadline cannot pass).
    func testACancelGivesTheCLIItsTerminationGraceToCleanUp() async throws {
        let hold = makeHold()
        let started = folder.appendingPathComponent("started")
        let marker = folder.appendingPathComponent("cleaned")
        let cli = try cleaningCLI(cleanupSeconds: 2, hold: hold, started: started, marker: marker)

        _ = try await cancelOnceStarted(cli, started: started) { transport in
            try await transport.run(
                arguments: [],
                terminationGracePeriod: .seconds(60),
                isCancelled: { false },
                onEvent: { _ in }
            )
        }

        XCTAssertTrue(fileExists(marker), "the CLI finished its own cleanup and exited by itself")
    }

    /// The grace is a bound, not a promise. A CLI that ignores SIGTERM lives until the
    /// grace ends and is then killed, so a cancel still ends the run.
    func testACLIThatIgnoresSIGTERMIsKilledWhenTheGraceEnds() async throws {
        let started = folder.appendingPathComponent("started")
        let pidFile = folder.appendingPathComponent("cli.pid")
        let cli = try fakeCLI("""
        #!/bin/sh
        trap '' TERM
        echo $$ > "\(pidFile.path)"
        echo started > "\(started.path)"
        while true; do /bin/sleep 1; done
        """)

        let elapsed = try await cancelOnceStarted(cli, started: started) { transport in
            try await transport.run(
                arguments: [],
                terminationGracePeriod: .seconds(1),
                isCancelled: { false },
                onEvent: { _ in }
            )
        }

        XCTAssertGreaterThanOrEqual(elapsed, .seconds(1), "SIGKILL waited for the whole grace")
        let pid = try XCTUnwrap(readPID(pidFile))
        defer { kill(pid, SIGKILL) }
        let gone = await waitUntil(timeout: .seconds(30)) { !ProcessTreeTerminator.processExists(pid: pid) }
        XCTAssertTrue(gone, "the grace ended, so the CLI was killed")
    }

    /// A run given no grace keeps the behaviour it had before this lane. SIGKILL
    /// follows SIGTERM at once, so the cleanup handler, which needs 20 seconds,
    /// never finishes.
    func testWithoutAGraceTheCancelStillKillsTheCLIAtOnce() async throws {
        let hold = makeHold()
        let started = folder.appendingPathComponent("started")
        let marker = folder.appendingPathComponent("cleaned")
        let cli = try cleaningCLI(cleanupSeconds: 20, hold: hold, started: started, marker: marker)

        _ = try await cancelOnceStarted(cli, started: started) { transport in
            try await transport.run(arguments: [], isCancelled: { false }, onEvent: { _ in })
        }

        XCTAssertFalse(fileExists(marker), "the default grace is zero, so the handler was cut off")
    }

    /// After a cancel with a grace no descendant of the CLI is left. The CLI leaves on
    /// SIGTERM, and the tools it started stay behind in the states a real tool can be
    /// in. One stops on SIGTERM and runs in a process group of its own, which is where
    /// `ToolProcess` puts every tool. One ignores SIGTERM and has a helper of its own in
    /// a third group, which only a walk of the process table can find. The grace ends
    /// and what is left is killed.
    func testNoDescendantOfTheCLISurvivesACancelWithAGrace() async throws {
        let cliPIDFile = folder.appendingPathComponent("cli.pid")
        let stopperPIDFile = folder.appendingPathComponent("stopper.pid")
        let ignorerPIDFile = folder.appendingPathComponent("ignorer.pid")
        let helperPIDFile = folder.appendingPathComponent("helper.pid")
        let helper = try script(named: "helper.sh", """
        #!/bin/sh
        trap '' TERM
        echo $$ > "\(helperPIDFile.path)"
        while true; do /bin/sleep 1; done
        """)
        let ignorer = try script(named: "ignorer.sh", """
        #!/bin/sh
        trap '' TERM
        echo $$ > "\(ignorerPIDFile.path)"
        set -m
        /bin/sh "\(helper.path)" &
        set +m
        while true; do /bin/sleep 1; done
        """)
        let stopper = try script(named: "stopper.sh", """
        #!/bin/sh
        trap 'exit 0' TERM
        echo $$ > "\(stopperPIDFile.path)"
        while true; do /bin/sleep 1; done
        """)
        let cli = try fakeCLI("""
        #!/bin/sh
        trap 'exit 0' TERM
        echo $$ > "\(cliPIDFile.path)"
        set -m
        /bin/sh "\(stopper.path)" &
        /bin/sh "\(ignorer.path)" &
        set +m
        while true; do /bin/sleep 1; done
        """)
        let transport = CLISubprocessTransport(cliURLOverride: cli)
        let task = Task {
            try await transport.run(
                arguments: [],
                terminationGracePeriod: .seconds(1),
                isCancelled: { false },
                onEvent: { _ in }
            )
        }

        var tools: [Int32] = []
        let up = await waitUntil(timeout: .seconds(30)) {
            tools = [cliPIDFile, stopperPIDFile, ignorerPIDFile, helperPIDFile].compactMap { readPID($0) }
            return tools.count == 4
        }
        defer { tools.forEach { kill($0, SIGKILL) } }
        guard up else {
            transport.cancel()
            return XCTFail("the stand-in CLI never started its tools")
        }
        let (cliPID, stopperPID, ignorerPID, helperPID) = (tools[0], tools[1], tools[2], tools[3])
        let tree = ProcessTreeTerminator.descendantProcessIDs(of: cliPID)
        XCTAssertTrue([stopperPID, ignorerPID, helperPID].allSatisfy(tree.contains), "the walk from the CLI reaches every tool, found \(tree)")
        XCTAssertNotEqual(getpgid(stopperPID), getpgid(cliPID), "a tool runs in a group of its own")
        XCTAssertNotEqual(getpgid(helperPID), getpgid(ignorerPID), "so does the helper of a tool")

        transport.cancel()
        let outcome = try await wait(for: task)
        guard case .failure(let error) = outcome else { return XCTFail("a cancelled run returns no result") }
        XCTAssertTrue(error is CancellationError, "\(error)")

        let everyone = tools + tree
        let gone = await waitUntil(timeout: .seconds(30)) {
            !everyone.contains { ProcessTreeTerminator.processExists(pid: $0) }
        }
        XCTAssertTrue(gone, "no descendant of the CLI survives, whatever its group or its answer to SIGTERM")
    }

    /// The drain grace reaches the run. The CLI exits at once and leaves a helper that
    /// holds its output open for six seconds. ToolProcess's own default of five seconds
    /// gives up on the helper and fails the run with incomplete output, so a run that
    /// succeeds was given the longer drain.
    func testTheDrainGracePeriodReachesTheRun() async throws {
        let complete = try completeLine(outputs: ["/tmp/result"])
        let cli = try fakeCLI("""
        #!/bin/sh
        /bin/sleep 6 &
        echo '\(complete)'
        """)
        let transport = CLISubprocessTransport(cliURLOverride: cli)
        let task = Task {
            try await transport.run(
                arguments: [],
                drainGracePeriod: .seconds(30),
                isCancelled: { false },
                onEvent: { _ in }
            )
        }

        let result = try await wait(for: task).get()
        XCTAssertEqual(result.outputs, ["/tmp/result"])
    }

    /// Writes an executable script named `name` beside the stand-in CLI.
    private func script(named name: String, _ body: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CLIEvent] = []
    var values: [CLIEvent] { lock.withLock { stored } }
    func append(_ event: CLIEvent) { lock.withLock { stored.append(event) } }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Swift.Result<CLISubprocessTransport.Result, Error>?
    var value: Swift.Result<CLISubprocessTransport.Result, Error>? { lock.withLock { stored } }
    func set(_ value: Swift.Result<CLISubprocessTransport.Result, Error>) { lock.withLock { stored = value } }
}
