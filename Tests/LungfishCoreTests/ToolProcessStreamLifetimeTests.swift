// ToolProcessStreamLifetimeTests.swift - Ownership, closing and idle limits of a streamed ToolProcess stdout
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Synchronization
import XCTest
@testable import LungfishCore
import LungfishTestSupport

/// Phase 2.2 lane 6A (R7). A streamed stdout whose handle is dropped ends
/// the run, a close never pulls the descriptor from under a reader, a result
/// taken before end of file is not a success, and bytes the reader takes
/// count as activity for the idle limit.
final class ToolProcessStreamLifetimeTests: XCTestCase {
    private typealias Fixtures = ToolProcessFixtures

    // MARK: - Dropped handle

    /// Nobody reads and nobody cancels. Dropping the handle closes the read
    /// end, so the writer gets SIGPIPE, and the run still reaps it and
    /// leaves the registry.
    func testDroppingAStreamedRunWithoutReadingEndsAndReapsIt() async throws {
        let pid = try Self.startAndDropYes()
        defer { Fixtures.killIfAlive(pid) }
        let reaped = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(20)) {
            if case .lost = ToolProcessSpawner.peekExit(pid) { return true }
            return false
        }
        XCTAssertTrue(reaped, "the writer of a dropped stream must end and be reaped")
        let unregistered = await waitUntil(timeout: .seconds(30)) {
            !NativeProcessRegistry.shared.isRegistered(processGroupLeader: pid)
        }
        XCTAssertTrue(unregistered, "a finished run leaves the registry")
    }

    private static func startAndDropYes() throws -> Int32 {
        let run = try ToolProcess.start(ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
            environment: [:],
            stdout: .stream,
            label: "yes"
        ))
        guard let pid = run.pid else { throw ToolProcessError.invalidSpec("yes did not launch") }
        return pid
    }

    // MARK: - Close while reading

    /// A writer outside the run's group keeps the pipe full, so a reader is
    /// always inside a read. Cancelling and taking the result closes the
    /// stream under it. The reader must never touch the descriptor after the
    /// close, which a descriptor reused by a new pipe would expose, and the
    /// flags must say the stream ended before end of file.
    func testClosingWhileAReaderIsActiveNeverReadsAClosedDescriptor() async throws {
        let perl = URL(fileURLWithPath: "/usr/bin/perl")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: perl.path), "needs /usr/bin/perl for setsid")
        let directory = try makeToolProcessTempDirectory()
        let pidFile = directory.appendingPathComponent("holder.pid")
        let perlScript = "my $f = shift; if (fork() == 0) { POSIX::setsid(); open(my $h, '>', $f); print $h \"$$\\n\"; " +
            "close $h; exec('/usr/bin/yes', 'stream') } until (-s $f) { select(undef, undef, undef, 0.01) }"
        let run = try ToolProcess.start(Fixtures.shell(
            "perl -MPOSIX -e \(Fixtures.shellQuote(perlScript)) \(Fixtures.shellQuote(pidFile.path)); sleep 30",
            stdout: .stream,
            stderr: .discard
        ))
        let holder = await Fixtures.waitForPID(pidFile)
        defer { Fixtures.killIfAlive(holder) }
        XCTAssertNotNil(holder)

        let marker = Data("LGE-REUSED-DESCRIPTOR".utf8)
        let sawMarker = ToolProcessTestBox(false)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue(label: "busy-reader").async {
            var signalled = false
            while true {
                let chunk = run.stdout.read(upTo: 4096)
                if chunk.isEmpty { break }
                if chunk.range(of: marker) != nil { sawMarker.withLock { $0 = true } }
                if !signalled {
                    signalled = true
                    started.signal()
                }
            }
            finished.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 30), .success)
        try await Task.sleep(for: .milliseconds(100))

        run.cancel()
        do {
            _ = try await run.result()
            XCTFail("Expected a cancellation")
        } catch .cancelled(let results) {
            XCTAssertEqual(results.first?.outputDrainTimedOut, true, "a stream closed before end of file is incomplete")
        }
        // Any descriptor the stream gave back is taken at once by pipes that
        // hold the marker, so a read after the close would return it.
        var decoys: [Int32] = []
        for _ in 0..<8 {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { break }
            marker.withUnsafeBytes { _ = Darwin.write(fds[1], $0.baseAddress, $0.count) }
            decoys += fds
        }
        defer { decoys.forEach { Darwin.close($0) } }

        XCTAssertEqual(finished.wait(timeout: .now() + 30), .success, "the close must end the reader")
        XCTAssertFalse(sawMarker.withLock { $0 }, "the reader read a descriptor after the stream closed it")
        XCTAssertFalse(run.stdout.readFailed, "no read may fail on a closed descriptor")
        XCTAssertTrue(run.stdout.endedWithoutEndOfFile, "the stream was closed before end of file")
        if let holder {
            // The real close came once the reader left, so the holder's next write gets SIGPIPE.
            let holderEnded = await Fixtures.waitForExit(holder)
            XCTAssertTrue(holderEnded, "the read end must really close after the last reader leaves")
        }
    }

    /// The process wrote bytes nobody read. Taking the result closes the
    /// stream, and the result must not call that output complete.
    func testResultBeforeTheReaderReachedEndOfFileIsNotASuccess() async throws {
        let run = try ToolProcess.start(Fixtures.shell("printf hello", stdout: .stream))
        let result = try await run.result()
        XCTAssertEqual(result.termination, .exited(code: 0))
        XCTAssertFalse(result.outputComplete, "five unread bytes were left in the pipe")
        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(run.stdout.endedWithoutEndOfFile)
    }

    /// Nothing was written, so nothing was left unread, and the run succeeds
    /// even though the caller never read.
    func testResultWithNothingLeftUnreadIsASuccess() async throws {
        let run = try ToolProcess.start(Fixtures.shell("exit 0", stdout: .stream))
        let result = try await run.result()
        XCTAssertTrue(result.isSuccess)
        XCTAssertFalse(run.stdout.endedWithoutEndOfFile)
    }

    // MARK: - Idle limit

    /// Output arrives only on the streamed stdout, every 250 ms for 2.5 s,
    /// and stderr stays silent. A 1 second idle limit must not fire.
    func testBytesReadFromAStreamedStdoutKeepTheIdleLimitFromFiring() async throws {
        let run = try ToolProcess.start(Fixtures.shell(
            "i=0; while [ $i -lt 10 ]; do echo tick; sleep 0.25; i=$((i+1)); done",
            stdout: .stream,
            stderr: .capture(),
            timeout: .seconds(60),
            idleTimeout: .seconds(1)
        ))
        let bytes = await run.stdout.drain(Data()) { collected, chunk in
            collected.append(chunk)
            return true
        }
        let result = try await run.result()
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self).split(separator: "\n").count, 10)
    }

    /// The streamed stdout is the only observed output. Once it stalls, the
    /// idle limit fires and the blocked reader ends.
    func testIdleLimitFiresWhenAStreamedStdoutStalls() async throws {
        let run = try ToolProcess.start(Fixtures.shell(
            "echo begun; exec sleep 30",
            stdout: .stream,
            stderr: .discard,
            timeout: .seconds(60),
            idleTimeout: .milliseconds(500)
        ))
        let bytes = await run.stdout.drain(Data()) { collected, chunk in
            collected.append(chunk)
            return true
        }
        XCTAssertEqual(bytes, Data("begun\n".utf8))
        do {
            _ = try await run.result()
            XCTFail("Expected an idle timeout")
        } catch .timedOut(let timeout, _) {
            XCTAssertEqual(timeout, .idle(.milliseconds(500)))
        }
    }
}
