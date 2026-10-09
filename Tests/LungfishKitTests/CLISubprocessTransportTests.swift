// CLISubprocessTransportTests.swift - lungfish-cli runs on ToolProcess, so output never deadlocks and a cancel stops the tree
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
import LungfishCore
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
        XCTAssertEqual(events.values, [.progress(fraction: 0.5, message: "halfway")])
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
        let started = await waitUntil(timeout: .seconds(10)) {
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
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(100), "cancel returns at once")

        let outcome = try await wait(for: task)
        guard case .failure(let error) = outcome else { return XCTFail("a cancelled run returns no result") }
        XCTAssertTrue(error is CancellationError, "\(error)")
        let gone = await waitUntil(timeout: .seconds(10)) { !ProcessTreeTerminator.processExists(pid: pid) }
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
        let started = await waitUntil(timeout: .seconds(10)) {
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
        let gone = await waitUntil(timeout: .seconds(10)) { !ProcessTreeTerminator.processExists(pid: pid) }
        XCTAssertTrue(gone)
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
