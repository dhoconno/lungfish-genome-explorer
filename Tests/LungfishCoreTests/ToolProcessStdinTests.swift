// ToolProcessStdinTests.swift - Stdin fed by ToolProcess, from bytes given up front and from the caller while the process runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore
import LungfishTestSupport

/// Phase 2.13 lane 13.05. The first tests pin the `.data` feed as it was
/// before caller-fed stdin, so the writer it now shares with `.stream` keeps
/// its behaviour.
final class ToolProcessStdinTests: XCTestCase {
    private typealias Fixtures = ToolProcessFixtures

    /// Far more than a pipe holds, so the feed is still writing when the child exits.
    private static let largeInput = Data(repeating: UInt8(ascii: "x"), count: 4 * 1024 * 1024)

    // MARK: - The .data feed

    /// A child that exits without reading ends the feed. The broken pipe
    /// reaches neither the child's result nor this process as SIGPIPE.
    func testDataFeedEndsWhenTheChildExitsWithoutReading() async throws {
        let result = try await ToolProcess.run(Fixtures.shell("exit 0", stdin: .data(Self.largeInput)))
        XCTAssertEqual(result.termination, .exited(code: 0))
        XCTAssertTrue(result.isSuccess)
    }

    /// A child that reads a few bytes and exits ends the feed the same way,
    /// and what it read is its output.
    func testDataFeedEndsWhenTheChildExitsAfterReadingAFewBytes() throws {
        let result = try ToolProcess.runBlocking(Fixtures.shell("head -c 3", stdin: .data(Self.largeInput)))
        XCTAssertEqual(result.termination, .exited(code: 0))
        XCTAssertEqual(result.stdoutText, "xxx")
        XCTAssertTrue(result.isSuccess)
    }

    /// Every byte reaches a child that reads to end of file, and the feed's
    /// close gives it that end of file.
    func testDataFeedDeliversEveryByteAndThenEndOfFile() async throws {
        let result = try await ToolProcess.run(Fixtures.shell("wc -c", stdin: .data(Self.largeInput)))
        XCTAssertEqual(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "\(Self.largeInput.count)")
        XCTAssertTrue(result.isSuccess)
    }

    // MARK: - A streamed stdin

    /// 8 MB, far more than the pipe holds, written while the child sleeps
    /// before it reads. The writes wait for the reader, which is the
    /// backpressure, and every byte arrives in order.
    func testWriteLargerThanThePipeWaitsForASlowReaderAndArrivesByteExact() throws {
        let directory = try makeToolProcessTempDirectory()
        let output = directory.appendingPathComponent("out.bin")
        let input = ToolProcessStreamTests.pseudoRandomBytes(count: 8 * 1024 * 1024)
        let run = try ToolProcess.start(Fixtures.shell(
            "sleep 0.5; exec cat",
            stdin: .stream,
            stdout: .file(output)
        ))
        let clock = ContinuousClock()
        let started = clock.now
        let chunk = 256 * 1024
        for offset in stride(from: 0, to: input.count, by: chunk) {
            try run.stdin.writeBlocking(input.subdata(in: offset..<min(offset + chunk, input.count)))
        }
        let written = started.duration(to: clock.now)
        run.stdin.close()
        let result = try run.waitBlocking()

        XCTAssertGreaterThanOrEqual(written, .milliseconds(300), "the writes must wait for the sleeping reader")
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(try Data(contentsOf: output), input)
    }

    /// Async writes suspend instead of holding a thread, and closing the
    /// writer gives the child end of file.
    func testAsyncWritesReachTheChildAndCloseGivesEndOfFile() async throws {
        let run = try ToolProcess.start(Fixtures.shell("wc -c", stdin: .stream))
        let chunk = Data(repeating: UInt8(ascii: "y"), count: 100_000)
        for _ in 0..<10 {
            try await run.stdin.write(chunk)
        }
        run.stdin.close()
        let result = try await run.result()
        XCTAssertEqual(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "1000000")
        XCTAssertTrue(result.isSuccess)
        do {
            try await run.stdin.write(chunk)
            XCTFail("a write after close must be refused")
        } catch {
            XCTAssertEqual(error, .closed)
        }
    }

    /// A child that never reads and exits ends a write waiting on the full
    /// pipe with readerGone. Nothing dies of SIGPIPE, the run succeeds, and
    /// later writes report the same.
    func testChildThatNeverReadsAndExitsEndsAWaitingWriteWithReaderGone() async throws {
        let run = try ToolProcess.start(Fixtures.shell("sleep 0.3; exit 0", stdin: .stream))
        do {
            try await run.stdin.write(Self.largeInput)
            XCTFail("the write must not complete into a pipe nobody reads")
        } catch {
            XCTAssertEqual(error, .readerGone)
        }
        do {
            try await run.stdin.write(Data("more".utf8))
            XCTFail("a write after the reader left must be refused")
        } catch {
            XCTAssertEqual(error, .readerGone)
        }
        run.stdin.close()
        let result = try await run.result()
        XCTAssertEqual(result.termination, .exited(code: 0))
        XCTAssertTrue(result.isSuccess)
    }

    /// A child that reads a few bytes and exits ends the write the same way,
    /// and what it read is its output.
    func testChildThatExitsEarlyEndsTheWriteWithReaderGone() async throws {
        let run = try ToolProcess.start(Fixtures.shell("head -c 5", stdin: .stream))
        do {
            try await run.stdin.write(Self.largeInput)
            XCTFail("the write must end when the reader exits")
        } catch {
            XCTAssertEqual(error, .readerGone)
        }
        let result = try await run.result()
        XCTAssertEqual(result.stdoutText, "xxxxx")
        XCTAssertTrue(result.isSuccess)
    }

    /// A cancel while a write waits on a child that never reads tears the
    /// tree down, releases the writer and leaves no process behind.
    func testCancelWithAWritePendingReleasesTheWriterAndLeavesNoChild() throws {
        let directory = try makeToolProcessTempDirectory()
        let pidFile = directory.appendingPathComponent("sleeper.pid")
        let run = try ToolProcess.start(Fixtures.shell(
            "sleep 30 & echo $! > \(Fixtures.shellQuote(pidFile.path)); wait",
            stdin: .stream
        ))
        let sleeper = try XCTUnwrap(ToolProcessStreamTests.waitForPID(pidFile))
        defer { Fixtures.killIfAlive(sleeper) }
        let outcome = ToolProcessTestBox<ToolProcessInputStream.WriteError?>(nil)
        let writerDone = DispatchSemaphore(value: 0)
        DispatchQueue(label: "pending-writer").async {
            do throws(ToolProcessInputStream.WriteError) {
                try run.stdin.writeBlocking(Self.largeInput)
            } catch {
                outcome.withLock { $0 = error }
            }
            writerDone.signal()
        }
        usleep(200_000)
        XCTAssertEqual(writerDone.wait(timeout: .now()), .timedOut, "the write must wait on the full pipe")

        run.cancel()
        XCTAssertEqual(writerDone.wait(timeout: .now() + 30), .success, "cancel must release the pending writer")
        XCTAssertEqual(outcome.withLock { $0 }, .readerGone)
        do {
            _ = try run.waitBlocking()
            XCTFail("Expected a cancellation")
        } catch .cancelled(let results) {
            XCTAssertEqual(results.first?.stop, .cancelled)
        }
        XCTAssertTrue(Self.waitForExit(sleeper), "the sleeping descendant must be dead")
    }

    /// A wall-clock limit does the same for a write that waits.
    func testTimeoutWithAWritePendingReleasesTheWriter() async throws {
        let run = try ToolProcess.start(Fixtures.shell("sleep 30", stdin: .stream, timeout: .milliseconds(500)))
        do {
            try await run.stdin.write(Self.largeInput)
            XCTFail("the write must end when the limit stops the child")
        } catch {
            XCTAssertEqual(error, .readerGone)
        }
        do {
            _ = try await run.result()
            XCTFail("Expected a timeout")
        } catch .timedOut(let timeout, _) {
            XCTAssertEqual(timeout, .wallClock(.milliseconds(500)))
        }
    }

    /// Dropping the handle closes the writer, so a child reading to end of
    /// file still ends.
    func testDroppingTheHandleGivesTheChildEndOfFile() async throws {
        let directory = try makeToolProcessTempDirectory()
        let output = directory.appendingPathComponent("out.txt")
        let marker = directory.appendingPathComponent("done")
        try Self.startWriteAndDrop(Fixtures.shell(
            "cat > \(Fixtures.shellQuote(output.path)); touch \(Fixtures.shellQuote(marker.path))",
            stdin: .stream
        ))
        let ended = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(20)) {
            FileManager.default.fileExists(atPath: marker.path)
        }
        XCTAssertTrue(ended, "a dropped writer must give the child end of file")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "abc")
    }

    /// A run that does not stream stdin, or never launched, has a writer
    /// that refuses every write.
    func testWriterRefusesWhenStdinIsNotStreamedOrNothingLaunched() async throws {
        let plain = try ToolProcess.start(Fixtures.shell("true"))
        do {
            try await plain.stdin.write(Data("x".utf8))
            XCTFail("a run without a streamed stdin has no writer")
        } catch {
            XCTAssertEqual(error, .closed)
        }
        _ = try await plain.result()
        let ghost = try ToolProcess.start(ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/nonexistent/tool"),
            environment: [:],
            stdin: .stream
        ))
        do {
            try await ghost.stdin.write(Data("x".utf8))
            XCTFail("nothing launched, so nothing reads")
        } catch {
            XCTAssertEqual(error, .readerGone)
        }
        do {
            _ = try await ghost.result()
            XCTFail("Expected a launch failure")
        } catch .launchFailed {}
    }

    func testOnlyStartAcceptsAStreamedStdin() async throws {
        let streamed = Fixtures.shell("cat", stdin: .stream)
        do {
            _ = try await ToolProcess.run(streamed)
            XCTFail("run must refuse a streamed stdin")
        } catch .invalidSpec(let reason) {
            XCTAssertEqual(reason, "sh streams stdin, which needs ToolProcess.start and a writer. run has none.")
        }
        do {
            _ = try ToolProcess.runBlocking(streamed)
            XCTFail("runBlocking must refuse a streamed stdin")
        } catch .invalidSpec(let reason) {
            XCTAssertEqual(reason, "sh streams stdin, which needs ToolProcess.start and a writer. runBlocking has none.")
        }
        do {
            _ = try await ToolProcess.runPipeline([streamed, Fixtures.shell("cat")])
            XCTFail("runPipeline must refuse a streamed stdin")
        } catch .invalidSpec(let reason) {
            XCTAssertEqual(reason, "sh streams stdin, which needs ToolProcess.start and a writer. runPipeline has none.")
        }
    }

    // MARK: - Helpers

    /// Waits up to 30 seconds for `pid` to be gone, returning as soon as it is.
    static func waitForExit(_ pid: Int32, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !ProcessTreeTerminator.processExists(pid: pid) { return true }
            usleep(20_000)
        }
        return !ProcessTreeTerminator.processExists(pid: pid)
    }

    private static func startWriteAndDrop(_ spec: ToolProcessSpec) throws {
        let run = try ToolProcess.start(spec)
        try run.stdin.writeBlocking(Data("abc".utf8))
    }
}
