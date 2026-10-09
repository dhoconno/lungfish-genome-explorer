// ToolProcessStreamTests.swift - The ToolProcessRun handle and its streamed stdout
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import XCTest
@testable import LungfishCore
import LungfishTestSupport

final class ToolProcessStreamTests: XCTestCase {
    private typealias Fixtures = ToolProcessFixtures

    /// 50 MB of bytes with every value, CRs included, read 64 KB at a time
    /// by a reader that pauses. The reader holds one chunk at a time and the
    /// run keeps no bytes, so memory stays bounded however large the stream.
    /// While the reader pauses, cat must still be running, blocked on the
    /// full pipe, which is the backpressure.
    func testFiftyMegabytesStreamByteExactThroughASlowReader() throws {
        let directory = try makeToolProcessTempDirectory()
        let input = directory.appendingPathComponent("input.bin")
        let size = 50 * 1024 * 1024
        try Self.pseudoRandomBytes(count: size).write(to: input)

        let pid = ToolProcessTestBox<Int32>(0)
        let run = try ToolProcess.start(
            ToolProcessSpec(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: [input.path],
                environment: ["PATH": Fixtures.systemPath],
                stdout: .stream,
                label: "cat"
            ),
            onLaunch: { launched in pid.withLock { $0 = launched } }
        )
        let expected = try FileHandle(forReadingFrom: input)
        defer { try? expected.close() }

        let outcome = ToolProcessTestBox<(bytes: Int, mismatchAt: Int?, heldBackWhilePaused: Bool)>((0, nil, false))
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue(label: "slow-reader").async {
            var offset = 0
            var chunks = 0
            var heldBack = false
            while true {
                let chunk = run.stdout.read(upTo: 64 * 1024)
                if chunk.isEmpty { break }
                let reference = expected.readData(ofLength: chunk.count)
                if reference != chunk {
                    outcome.withLock { $0.mismatchAt = offset }
                    break
                }
                offset += chunk.count
                chunks += 1
                if chunks == 1 {
                    // Pause long enough for cat to fill the pipe and block.
                    usleep(400_000)
                    let catPID = pid.withLock { $0 }
                    heldBack = ToolProcessTreeProbe.isRunning(catPID)
                } else if chunks % 64 == 0 {
                    usleep(2_000)
                }
            }
            outcome.withLock { $0.bytes = offset; $0.heldBackWhilePaused = heldBack }
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 120), .success, "the reader did not reach end of file")
        let result = try run.waitBlocking()

        let observed = outcome.withLock { $0 }
        XCTAssertNil(observed.mismatchAt, "streamed bytes differ from the file")
        XCTAssertEqual(observed.bytes, size)
        XCTAssertTrue(observed.heldBackWhilePaused, "cat must be held back by the full pipe while the reader pauses")
        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(result.stdout.isEmpty, "a streamed stdout keeps no bytes in the result")
    }

    /// A single line far over the 64 KB framing limit and lone CRs reach the
    /// reader exactly as written, with no cut and no line splitting.
    func testLongLineAndLoneCarriageReturnsPassThroughUntouched() async throws {
        let script = "head -c 200000 /dev/zero | tr '\\000' A; printf '\\rB\\rC\\r\\nD\\r'"
        let run = try ToolProcess.start(Fixtures.shell(script, stdout: .stream))
        let bytes = await run.stdout.drain(Data()) { collected, chunk in
            collected.append(chunk)
            return true
        }
        let result = try await run.result()

        var expected = Data(repeating: UInt8(ascii: "A"), count: 200_000)
        expected.append(contentsOf: Array("\rB\rC\r\nD\r".utf8))
        XCTAssertEqual(bytes, expected)
        XCTAssertTrue(result.isSuccess)
    }

    /// Cancelling the run while the reader is blocked on an empty pipe kills
    /// the tree, which ends the read, and the result is a cancellation.
    func testCancellingWhileTheReaderIsBlockedEndsTheReadAndKillsTheTree() throws {
        let directory = try makeToolProcessTempDirectory()
        let pidFile = directory.appendingPathComponent("sleeper.pid")
        let run = try ToolProcess.start(
            Fixtures.shell("printf start; sleep 30 & echo $! > \(Fixtures.shellQuote(pidFile.path)); wait", stdout: .stream)
        )
        let readBytes = ToolProcessTestBox(Data())
        let blocked = DispatchSemaphore(value: 0)
        let readerDone = DispatchSemaphore(value: 0)
        DispatchQueue(label: "blocked-reader").async {
            var signalled = false
            while true {
                let chunk = run.stdout.read(upTo: 4096)
                if chunk.isEmpty { break }
                readBytes.withLock { $0.append(chunk) }
                if !signalled {
                    signalled = true
                    blocked.signal()
                }
            }
            readerDone.signal()
        }
        XCTAssertEqual(blocked.wait(timeout: .now() + 10), .success)
        let sleeper = try XCTUnwrap(Self.waitForPID(pidFile))
        defer { Fixtures.killIfAlive(sleeper) }
        // The reader is now parked on a pipe that will not be written again.
        usleep(200_000)
        XCTAssertEqual(readerDone.wait(timeout: .now()), .timedOut, "the reader must still be blocked")

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        run.cancel()
        XCTAssertEqual(readerDone.wait(timeout: .now() + 10), .success, "cancel must end a blocked read")
        XCTAssertLessThan(cancelledAt.duration(to: clock.now), .seconds(5))
        XCTAssertEqual(readBytes.withLock { $0 }, Data("start".utf8))
        do {
            _ = try run.waitBlocking()
            XCTFail("Expected a cancellation")
        } catch .cancelled(let results) {
            XCTAssertEqual(results.first?.stop, .cancelled)
        }
        XCTAssertFalse(ProcessTreeTerminator.processExists(pid: sleeper), "the sleeping descendant must be dead")
    }

    /// A background descendant in the run's group keeps the pipe open after
    /// the root exits. Once the drain grace runs out it is killed, the reader
    /// reaches end of file, and the result reports the output incomplete.
    func testLingeringWriterIsKilledAndTheOutputReportedIncomplete() throws {
        let directory = try makeToolProcessTempDirectory()
        let pidFile = directory.appendingPathComponent("lingering.pid")
        let run = try ToolProcess.start(
            Fixtures.shell(
                "sleep 30 & echo $! > \(Fixtures.shellQuote(pidFile.path)); printf hello",
                stdout: .stream,
                drainGracePeriod: .milliseconds(300)
            )
        )
        let bytes = Self.readToEnd(run.stdout)
        let result = try run.waitBlocking()
        let lingering = try XCTUnwrap(Fixtures.readPID(pidFile))
        defer { Fixtures.killIfAlive(lingering) }

        XCTAssertEqual(bytes, Data("hello".utf8))
        XCTAssertEqual(result.termination, .exited(code: 0))
        XCTAssertTrue(result.outputDrainTimedOut)
        XCTAssertFalse(result.outputComplete)
        XCTAssertFalse(result.isSuccess)
        XCTAssertFalse(ProcessTreeTerminator.processExists(pid: lingering))
    }

    /// A writer that left the run's process group cannot be killed through
    /// it. The reader must still stop once the run is over and the pipe is
    /// empty, and the result must not pass as complete.
    func testWriterOutsideTheGroupDoesNotHoldTheReaderAfterTheRunEnds() throws {
        let perl = URL(fileURLWithPath: "/usr/bin/perl")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: perl.path), "needs /usr/bin/perl for setsid")
        let directory = try makeToolProcessTempDirectory()
        let pidFile = directory.appendingPathComponent("escaped.pid")
        // The child leaves the group with setsid, records its pid, and keeps
        // the inherited stdout open. The parent waits for the record, so the
        // child is out of the group before the root exits.
        let perlScript = "my $f = shift; if (fork() == 0) { POSIX::setsid(); open(my $h, '>', $f); print $h \"$$\\n\"; " +
            "close $h; sleep 30; exit 0 } until (-s $f) { select(undef, undef, undef, 0.01) }"
        let run = try ToolProcess.start(Fixtures.shell(
            "perl -MPOSIX -e \(Fixtures.shellQuote(perlScript)) \(Fixtures.shellQuote(pidFile.path)); printf hello",
            stdout: .stream,
            // A captured stderr would also be held open and cut short, so
            // only the stream is left to show the escaped writer.
            stderr: .discard
        ))
        let clock = ContinuousClock()
        let started = clock.now
        let bytes = Self.readToEnd(run.stdout)
        let result = try run.waitBlocking()
        let escaped = Fixtures.readPID(pidFile)
        defer { Fixtures.killIfAlive(escaped) }

        XCTAssertNotNil(escaped)
        XCTAssertTrue(escaped.map(ToolProcessTreeProbe.isRunning) ?? false, "the escaped writer still holds the pipe")
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(10), "the reader must not wait for the escaped writer")
        XCTAssertEqual(bytes, Data("hello".utf8))
        XCTAssertTrue(run.stdout.endedWithoutEndOfFile)
        XCTAssertTrue(result.outputDrainTimedOut, "the reader's early end is folded into the result")
        XCTAssertFalse(result.outputComplete)
        XCTAssertFalse(result.isSuccess)
    }

    func testOnlyStartAcceptsAStreamedStdout() async throws {
        let streamed = Fixtures.shell("echo hi", stdout: .stream)
        do {
            _ = try await ToolProcess.run(streamed)
            XCTFail("run must refuse a streamed stdout")
        } catch .invalidSpec {}
        do {
            _ = try await ToolProcess.runPipeline([Fixtures.shell("echo hi"), Fixtures.shell("cat", stdout: .stream)])
            XCTFail("runPipeline must refuse a streamed stdout")
        } catch .invalidSpec {}
        do {
            _ = try ToolProcess.runBlocking(streamed)
            XCTFail("runBlocking must refuse a streamed stdout")
        } catch .invalidSpec {}
        do {
            _ = try ToolProcess.start(Fixtures.shell("echo hi", stderr: .stream))
            XCTFail("stderr cannot stream")
        } catch .invalidSpec {}
    }

    /// Without a streamed stdout the reader is at end of file at once, and a
    /// started run otherwise behaves as `run` does.
    func testStartWithoutAStreamCapturesAsRunDoes() async throws {
        let run = try ToolProcess.start(Fixtures.shell("echo out; echo err >&2; exit 3"))
        XCTAssertTrue(run.stdout.read(upTo: 16).isEmpty)
        let result = try await run.result()
        XCTAssertEqual(result.termination, .exited(code: 3))
        XCTAssertEqual(result.stdoutText, "out\n")
        XCTAssertEqual(result.stderrText, "err\n")
        XCTAssertEqual(run.pid, result.pid, "the pid is set once start returns")
        let again = try await run.result()
        XCTAssertEqual(again.pid, result.pid, "the result is kept for later calls")
    }

    func testLaunchFailureLeavesNoPidAndIsTheErrorOfTheResult() throws {
        let run = try ToolProcess.start(ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/nonexistent/tool"),
            environment: [:],
            stdout: .stream
        ))
        XCTAssertNil(run.pid)
        XCTAssertTrue(run.stdout.read(upTo: 16).isEmpty)
        do {
            _ = try run.waitBlocking()
            XCTFail("Expected a launch failure")
        } catch .launchFailed(let label, _, _) {
            XCTAssertEqual(label, "tool")
        }
    }

    // MARK: - Helpers

    static func readToEnd(_ stream: ToolProcessOutputStream) -> Data {
        var data = Data()
        while true {
            let chunk = stream.read(upTo: 64 * 1024)
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
    }

    static func waitForPID(_ url: URL, timeout: TimeInterval = 10) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = Fixtures.readPID(url) { return pid }
            usleep(20_000)
        }
        return nil
    }

    /// Deterministic bytes covering every value, CR and LF included.
    static func pseudoRandomBytes(count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            for index in words.indices {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                words[index] = state ^ (state >> 29)
            }
        }
        return data
    }
}

/// A value behind a lock that escaping closures can share.
final class ToolProcessTestBox<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { body(&$0) }
    }
}

/// Whether a pid is a live, unexited process.
enum ToolProcessTreeProbe {
    static func isRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size) }
        return result == size && info.pbi_status != UInt32(SZOMB)
    }
}
