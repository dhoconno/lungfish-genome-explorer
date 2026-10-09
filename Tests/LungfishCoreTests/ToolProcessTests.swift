// ToolProcessTests.swift - Single-process behaviour of ToolProcess.run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore
import LungfishTestSupport

final class ToolProcessTests: XCTestCase {
    private typealias Fixtures = ToolProcessFixtures

    // MARK: - Output

    /// A reader that drains stdout first and stderr only after exit blocks
    /// forever once stderr fills its 64 KB pipe buffer. Both streams here are
    /// far larger than that, and stderr is written first.
    func testLargeOutputOnBothStreamsDoesNotDeadlock() async throws {
        let spec = Fixtures.shell(
            "yes err | head -c 400000 >&2; yes out | head -c 400000; yes err | head -c 100000 >&2",
            timeout: .seconds(60)
        )
        let result = try await ToolProcess.run(spec)
        XCTAssertEqual(result.termination, .exited(code: 0))
        XCTAssertEqual(result.stdout.count, 400_000)
        XCTAssertEqual(result.stderr.count, 500_000)
        XCTAssertFalse(result.stdoutTruncated)
        XCTAssertFalse(result.stderrTruncated)
        XCTAssertFalse(result.outputDrainTimedOut)
        XCTAssertTrue(result.stdoutText.hasPrefix("out\nout\n"))
    }

    func testNonzeroExitIsReturnedNotThrown() async throws {
        let result = try await ToolProcess.run(Fixtures.shell("echo partial; echo why >&2; exit 3"))
        XCTAssertEqual(result.termination, .exited(code: 3))
        XCTAssertEqual(result.status, 3)
        XCTAssertFalse(result.isSuccess)
        XCTAssertNil(result.stop)
        XCTAssertEqual(result.stdoutText, "partial\n")
        XCTAssertEqual(result.stderrText, "why\n")
        XCTAssertGreaterThan(result.pid, 0)
        XCTAssertGreaterThan(result.wallTime, .zero)
    }

    func testUncaughtSignalIsReportedAsSignal() async throws {
        let result = try await ToolProcess.run(Fixtures.shell("kill -KILL $$"))
        XCTAssertEqual(result.termination, .signaled(signal: SIGKILL))
        XCTAssertEqual(result.status, SIGKILL)
        XCTAssertNil(result.stop)
    }

    func testStdoutToFileWritesTheFileAndCapturesNothing() async throws {
        let directory = try makeToolProcessTempDirectory()
        let output = directory.appendingPathComponent("out.txt")
        try Data("stale content that must be truncated".utf8).write(to: output)
        let events = ToolProcessEventLog()
        let result = try await ToolProcess.run(
            Fixtures.shell("printf 'abc\\ndef'; echo note >&2", stdout: .file(output))
        ) { events.append($0) }
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "abc\ndef")
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(events.lines(.stdout), [])
        XCTAssertEqual(events.lines(.stderr), ["note"])
    }

    func testDiscardedStreamsDeliverNothing() async throws {
        let events = ToolProcessEventLog()
        let result = try await ToolProcess.run(
            Fixtures.shell("echo out; echo err >&2", stdout: .discard, stderr: .discard)
        ) { events.append($0) }
        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertTrue(result.stderr.isEmpty)
        XCTAssertEqual(events.lines(.stdout) + events.lines(.stderr), [])
        guard case .started(let pid, _)? = events.all.first?.event, events.all.count == 1 else {
            return XCTFail("The started event must be delivered before the run returns")
        }
        XCTAssertEqual(pid, result.pid)
    }

    func testCaptureLimitKeepsTheLastBytesAndMarksTruncation() async throws {
        let result = try await ToolProcess.run(
            Fixtures.shell(
                "i=0; while [ $i -lt 20000 ]; do echo \"line $i\"; i=$((i+1)); done >&2; printf 0123456789",
                stdout: .capture(limit: 4),
                stderr: .capture(limit: 1000)
            )
        )
        XCTAssertEqual(result.stdoutText, "6789")
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertEqual(result.stderr.count, 1000)
        XCTAssertTrue(result.stderrTruncated)
        XCTAssertTrue(result.stderrText.hasSuffix("line 19999\n"))

        let small = try await ToolProcess.run(Fixtures.shell("printf abc", stdout: .capture(limit: 3)))
        XCTAssertEqual(small.stdoutText, "abc")
        XCTAssertFalse(small.stdoutTruncated)
    }

    func testCaptureLimitZeroStreamsLinesWithoutKeepingBytes() async throws {
        let events = ToolProcessEventLog()
        let result = try await ToolProcess.run(
            Fixtures.shell("echo one; echo two", stdout: .capture(limit: 0))
        ) { events.append($0) }
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertEqual(events.lines(.stdout), ["one", "two"])
    }

    // MARK: - Input

    func testStdinDataIsDeliveredInFull() async throws {
        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 % 251) })
        let spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            environment: [:],
            stdin: .data(payload),
            timeout: .seconds(60)
        )
        let result = try await ToolProcess.run(spec)
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.stdout, payload)
    }

    /// The child exits without reading. The feeder meets EPIPE, which must
    /// neither raise SIGPIPE in the test process nor hang the run.
    func testStdinDataThatIsNeverReadDoesNotHangOrSignal() async throws {
        let payload = Data(repeating: 0x41, count: 1_000_000)
        let result = try await ToolProcess.run(
            Fixtures.shell("exit 0", stdin: .data(payload), timeout: .seconds(30))
        )
        XCTAssertTrue(result.isSuccess)
    }

    func testEmptyStdinDataGivesImmediateEndOfFile() async throws {
        let spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/wc"),
            arguments: ["-c"],
            environment: [:],
            stdin: .data(Data()),
            timeout: .seconds(30)
        )
        let result = try await ToolProcess.run(spec)
        XCTAssertEqual(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "0")
    }

    func testStdinFileIsRead() async throws {
        let directory = try makeToolProcessTempDirectory()
        let input = directory.appendingPathComponent("in.txt")
        try Data("from a file\n".utf8).write(to: input)
        let spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            environment: [:],
            stdin: .file(input)
        )
        let result = try await ToolProcess.run(spec)
        XCTAssertEqual(result.stdoutText, "from a file\n")
    }

    func testNullStdinReadsEndOfFile() async throws {
        let result = try await ToolProcess.run(
            ToolProcessSpec(executableURL: URL(fileURLWithPath: "/bin/cat"), environment: [:], timeout: .seconds(10))
        )
        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(result.stdout.isEmpty)
    }

    // MARK: - Environment and launch

    func testEnvironmentIsExactlyTheSpecsEnvironment() async throws {
        let spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            environment: ["LUNGFISH_TOOL_PROCESS_PROBE": "1"]
        )
        let result = try await ToolProcess.run(spec)
        let lines = result.stdoutText.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("LUNGFISH_TOOL_PROCESS_PROBE=1"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("HOME=") })
        XCTAssertFalse(lines.contains { $0.hasPrefix("PATH=") })

        let merged = ToolProcessSpec.inheritedEnvironment(overriding: ["PATH": "/override"])
        XCTAssertEqual(merged["PATH"], "/override")
        XCTAssertEqual(merged["HOME"], ProcessInfo.processInfo.environment["HOME"])
    }

    func testWorkingDirectoryIsUsed() async throws {
        let directory = try makeToolProcessTempDirectory()
        var spec = ToolProcessSpec(executableURL: URL(fileURLWithPath: "/bin/pwd"), arguments: ["-P"], environment: [:])
        spec.workingDirectory = directory
        let result = try await ToolProcess.run(spec)
        let expected = try XCTUnwrap(realpath(directory.path, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        XCTAssertEqual(result.stdoutText.trimmingCharacters(in: .newlines), expected)
    }

    func testMissingExecutableThrowsLaunchFailed() async throws {
        let spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/nonexistent/lungfish-tool-\(UUID().uuidString)"),
            environment: [:],
            label: "ghost"
        )
        do {
            _ = try await ToolProcess.run(spec)
            XCTFail("Expected launchFailed")
        } catch ToolProcessError.launchFailed(let label, _, let results) {
            XCTAssertTrue(results.isEmpty)
            XCTAssertEqual(label, "ghost")
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testUnreadableStdinFileThrowsLaunchFailed() async throws {
        let spec = Fixtures.shell("cat", stdin: .file(URL(fileURLWithPath: "/nonexistent/input-\(UUID().uuidString)")))
        do {
            _ = try await ToolProcess.run(spec)
            XCTFail("Expected launchFailed")
        } catch ToolProcessError.launchFailed {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testIdleTimeoutWithoutCapturedStreamIsInvalid() async throws {
        let spec = Fixtures.shell("true", stdout: .discard, stderr: .discard, idleTimeout: .seconds(1))
        do {
            _ = try await ToolProcess.run(spec)
            XCTFail("Expected invalidSpec")
        } catch ToolProcessError.invalidSpec {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    // MARK: - Events

    /// The script prints one line, then waits for a file the observer creates
    /// only after seeing that line. It can only finish if lines arrive while
    /// the process is still running.
    func testEventsStreamLinesBeforeExit() async throws {
        let directory = try makeToolProcessTempDirectory()
        let marker = directory.appendingPathComponent("seen")
        let events = ToolProcessEventLog()
        let spec = Fixtures.shell(
            "echo first; while [ ! -f \(Fixtures.shellQuote(marker.path)) ]; do sleep 0.02; done; echo second; printf tail >&2",
            timeout: .seconds(30)
        )
        let result = try await ToolProcess.run(spec) { event in
            events.append(event)
            if event == .output(stream: .stdout, line: "first") {
                FileManager.default.createFile(atPath: marker.path, contents: nil)
            }
        }
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(events.lines(.stdout), ["first", "second"])
        XCTAssertEqual(events.lines(.stderr), ["tail"])
        guard case .started(let pid, let argv)? = events.all.first?.event else {
            return XCTFail("The first event must be started")
        }
        XCTAssertEqual(pid, result.pid)
        XCTAssertEqual(argv, spec.argv)
    }

    func testSplitUTF8AndCRLFAreFramedIntoLines() async throws {
        let events = ToolProcessEventLog()
        let result = try await ToolProcess.run(
            Fixtures.shell(#"{ printf '\316'; sleep 0.1; printf '\262\r'; sleep 0.1; printf '\n\nnext\rfinal'; } >&2"#)
        ) { events.append($0) }
        XCTAssertEqual(events.lines(.stderr), ["β", "", "next", "final"])
        XCTAssertEqual(result.stderrText, "β\r\n\nnext\rfinal")
    }

    /// A line over the default 64 KB arrives in pieces unless the spec raises
    /// its line limit, which a stream of JSON events needs.
    func testTheSpecsLineLimitDecidesWhereALongLineIsCut() async throws {
        let script = "/usr/bin/head -c 200000 /dev/zero | /usr/bin/tr '\\0' 'x'; echo"
        let defaultLines = ToolProcessEventLog()
        _ = try await ToolProcess.run(Fixtures.shell(script, stdout: .capture(limit: 0))) { defaultLines.append($0) }
        let pieces = defaultLines.lines(.stdout).filter { !$0.isEmpty }
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.allSatisfy { $0.utf8.count <= ProcessOutputLineFramer.defaultMaxLineBytes })
        XCTAssertEqual(pieces.reduce(0) { $0 + $1.utf8.count }, 200_000)

        var spec = Fixtures.shell(script, stdout: .capture(limit: 0))
        spec.maxLineBytes = 1 << 20
        let wideLines = ToolProcessEventLog()
        _ = try await ToolProcess.run(spec) { wideLines.append($0) }
        XCTAssertEqual(wideLines.lines(.stdout).filter { !$0.isEmpty }.map(\.utf8.count), [200_000])
    }

    // MARK: - Lingering descendants

    /// A background grandchild inherits stdout and keeps it open for 30 s.
    /// The run must return soon after the root exits, keep what was written,
    /// kill the grandchild and refuse to call the run a success, because the
    /// output may be incomplete.
    func testLingeringGrandchildHoldingThePipeDoesNotHang() async throws {
        let directory = try makeToolProcessTempDirectory()
        let pidFile = directory.appendingPathComponent("sleeper.pid")
        let spec = Fixtures.shell(
            "sleep 30 & echo $! > \(Fixtures.shellQuote(pidFile.path)); echo done",
            drainGracePeriod: .milliseconds(300)
        )
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await ToolProcess.run(spec)
        let elapsed = started.duration(to: clock.now)
        let sleeper = try XCTUnwrap(Fixtures.readPID(pidFile))
        defer { Fixtures.killIfAlive(sleeper) }

        // Well under the grandchild's 30 s, with room for the parallel unit tier.
        XCTAssertLessThan(elapsed, .seconds(20))
        XCTAssertEqual(result.termination, .exited(code: 0))
        XCTAssertFalse(result.isSuccess)
        XCTAssertFalse(result.outputComplete)
        XCTAssertTrue(result.outputDrainTimedOut)
        XCTAssertEqual(result.stdoutText, "done\n")
        XCTAssertFalse(ProcessTreeTerminator.processExists(pid: sleeper), "the run must kill the lingering writer before it returns")
    }

    /// bcftools and seqkit call exit(-1) on a missing input. waitid reports 24 bits
    /// of that value, but the exit code has always been the 8 bits wait(2) keeps.
    func testExitMinusOneReportsTwoHundredFiftyFive() async throws {
        let spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "exit(-1)"],
            environment: ToolProcessSpec.inheritedEnvironment()
        )
        let result = try await ToolProcess.run(spec)
        XCTAssertEqual(result.termination, .exited(code: 255))
        XCTAssertEqual(result.status, 255)
    }
}
