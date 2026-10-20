// ONTBarcodeDemuxSamtoolsSpawnPinTests.swift - What the ONT pipeline's samtools merge and index spawn does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import XCTest
@testable import LungfishWorkflow

/// Pins of `runSamtoolsMerge` and `runSamtoolsIndex`, which share `runSamtoolsProcess` (Phase 2.13 lane 13.10).
/// A stand-in `samtools` script logs one line per call, `cwd|env|[arg][arg]`, and acts by the word in the `mode`
/// file beside it. The pins pass on the `Process` spawn of the base and unchanged on the `ToolProcess` spawn.
final class ONTBarcodeDemuxSamtoolsSpawnPinTests: XCTestCase {
    private struct Fixture: Sendable {
        let directory: URL
        let samtools: URL
        let stderrURL: URL
        let pipeline = ONTBarcodeDemuxGenotypingPipeline()

        func calls() -> [String] {
            let text = (try? String(contentsOf: directory.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map(String.init)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private static let standInSamtools = #"""
    #!/bin/bash
    dir="$(cd "$(dirname "$0")" && pwd -P)"
    args=""
    for a in "$@"; do args="${args}[${a}]"; done
    printf '%s|%s|%s\n' "$(pwd -P)" "${LUNGFISH_ONT_PIN_ENV:-unset}" "$args" >> "$dir/calls.log"
    case "$(cat "$dir/mode")" in
      ok)
        echo "stderr line one" >&2
        echo "stderr line two" >&2
        exit 0 ;;
      fail)
        echo "intentional failure" >&2
        exit 19 ;;
      signal)
        echo "about to die" >&2
        kill -9 $$ ;;
      big)
        head -c 300000 /dev/zero | tr '\0' 'x' >&2
        echo >&2
        echo "tail marker" >&2
        exit 0 ;;
      hang)
        sleep 60 &
        echo $! > "$dir/child.pid"
        echo $$ > "$dir/self.pid"
        wait ;;
    esac
    """#

    private func makeFixture(mode: String) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ont-samtools-pin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let samtools = directory.appendingPathComponent("samtools")
        try Self.standInSamtools.write(to: samtools, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: samtools.path)
        try mode.write(to: directory.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        return Fixture(directory: directory, samtools: samtools,
                       stderrURL: directory.appendingPathComponent("out.samtools-index.stderr.log"))
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func readPID(_ url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func isGone(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == -1 && errno == ESRCH
    }

    func testIndexAndMergeRunSamtoolsWithEachArgumentWholeAndReturnTheStderrFileText() async throws {
        let oldMask = umask(0o022)
        defer { umask(oldMask) }
        setenv("LUNGFISH_ONT_PIN_ENV", "seen", 1)
        defer { unsetenv("LUNGFISH_ONT_PIN_ENV") }
        let workingFolder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .resolvingSymlinksInPath().path
        let fixture = try makeFixture(mode: "ok")
        defer { fixture.remove() }
        // An earlier run's log must not survive into this run's text.
        try "stale\n".write(to: fixture.stderrURL, atomically: true, encoding: .utf8)
        let awkward = "/tmp/a b/with \"quote\" and $dollar.bam"

        let indexText = try await fixture.pipeline.runSamtoolsIndex(
            samtoolsURL: fixture.samtools, arguments: ["index", awkward], stderrURL: fixture.stderrURL)
        XCTAssertEqual(indexText, "stderr line one\nstderr line two\n")
        XCTAssertEqual(try String(contentsOf: fixture.stderrURL, encoding: .utf8), indexText)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.stderrURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644,
                       "the stderr log reads like every other record under umask 022")

        let mergeStderr = fixture.directory.appendingPathComponent("out.samtools-merge.stderr.log")
        let mergeText = try await fixture.pipeline.runSamtoolsMerge(
            samtoolsURL: fixture.samtools, arguments: ["merge", "-f", "/out/m.bam", "/in/a.bam", "/in/b.bam"],
            stderrURL: mergeStderr)
        XCTAssertEqual(mergeText, "stderr line one\nstderr line two\n")
        XCTAssertEqual(fixture.calls(), [
            "\(workingFolder)|seen|[index][\(awkward)]",
            "\(workingFolder)|seen|[merge][-f][/out/m.bam][/in/a.bam][/in/b.bam]",
        ])
    }

    func testANonzeroExitThrowsProcessFailedWithItsStatusAndTheStderrText() async throws {
        let fixture = try makeFixture(mode: "fail")
        defer { fixture.remove() }
        for (tool, isMerge) in [("samtools merge", true), ("samtools index", false)] {
            do {
                if isMerge {
                    _ = try await fixture.pipeline.runSamtoolsMerge(
                        samtoolsURL: fixture.samtools, arguments: ["merge", "-f", "/o.bam", "/a.bam"],
                        stderrURL: fixture.stderrURL)
                } else {
                    _ = try await fixture.pipeline.runSamtoolsIndex(
                        samtoolsURL: fixture.samtools, arguments: ["index", "/o.bam"], stderrURL: fixture.stderrURL)
                }
                XCTFail("\(tool) must fail")
            } catch let error as ONTBarcodeDemuxGenotypingError {
                guard case .processFailed(let failedTool, let status, let stderr) = error else {
                    return XCTFail("Expected processFailed for \(tool), received \(error)")
                }
                XCTAssertEqual(failedTool, tool)
                XCTAssertEqual(status, 19)
                XCTAssertEqual(stderr, "intentional failure\n")
            }
        }
    }

    func testASamtoolsKilledBySignalThrowsProcessFailedWithTheSignalNumber() async throws {
        let fixture = try makeFixture(mode: "signal")
        defer { fixture.remove() }
        do {
            _ = try await fixture.pipeline.runSamtoolsIndex(
                samtoolsURL: fixture.samtools, arguments: ["index", "/o.bam"], stderrURL: fixture.stderrURL)
            XCTFail("A killed samtools must fail")
        } catch let error as ONTBarcodeDemuxGenotypingError {
            guard case .processFailed(let tool, let status, let stderr) = error else {
                return XCTFail("Expected processFailed, received \(error)")
            }
            XCTAssertEqual(tool, "samtools index")
            XCTAssertEqual(status, SIGKILL)
            XCTAssertEqual(stderr, "about to die\n")
        }
    }

    func testAStderrOfThreeHundredKilobytesComesBackWhole() async throws {
        let fixture = try makeFixture(mode: "big")
        defer { fixture.remove() }
        let text = try await fixture.pipeline.runSamtoolsIndex(
            samtoolsURL: fixture.samtools, arguments: ["index", "/o.bam"], stderrURL: fixture.stderrURL)
        XCTAssertEqual(text, String(repeating: "x", count: 300_000) + "\ntail marker\n")
    }

    func testACancelledRunStopsTheScriptAndItsChildAndThrowsCancellationError() async throws {
        let fixture = try makeFixture(mode: "hang")
        defer { fixture.remove() }
        let childFile = fixture.directory.appendingPathComponent("child.pid")
        let selfFile = fixture.directory.appendingPathComponent("self.pid")
        let task = Task {
            try await fixture.pipeline.runSamtoolsIndex(
                samtoolsURL: fixture.samtools, arguments: ["index", "/o.bam"], stderrURL: fixture.stderrURL)
        }
        let started = await waitUntil { readPID(childFile) != nil && readPID(selfFile) != nil }
        XCTAssertTrue(started, "the stand-in must start before the cancel")
        let childPID = try XCTUnwrap(readPID(childFile))
        let scriptPID = try XCTUnwrap(readPID(selfFile))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled run must throw")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
        let scriptGone = await waitUntil { isGone(scriptPID) }
        let childGone = await waitUntil { isGone(childPID) }
        XCTAssertTrue(scriptGone, "the cancelled samtools script must be gone")
        XCTAssertTrue(childGone, "the child of the cancelled script must be gone")
    }

    func testARunCancelledBeforeItStartsThrowsCancellationErrorAndLaunchesNothing() async throws {
        let fixture = try makeFixture(mode: "ok")
        defer { fixture.remove() }
        let task = Task {
            while !Task.isCancelled { try await Task.sleep(nanoseconds: 1_000_000) }
            return try await fixture.pipeline.runSamtoolsIndex(
                samtoolsURL: fixture.samtools, arguments: ["index", "/o.bam"], stderrURL: fixture.stderrURL)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled run must throw")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
        XCTAssertEqual(fixture.calls(), [])
    }

    func testAnUnlaunchableSamtoolsIsNeitherACancellationNorASamtoolsFailure() async throws {
        let fixture = try makeFixture(mode: "ok")
        defer { fixture.remove() }
        do {
            _ = try await fixture.pipeline.runSamtoolsIndex(
                samtoolsURL: fixture.directory.appendingPathComponent("missing-samtools"),
                arguments: ["index", "/o.bam"], stderrURL: fixture.stderrURL)
            XCTFail("A samtools that cannot launch must fail")
        } catch is CancellationError {
            XCTFail("A launch failure is not a cancellation")
        } catch let error as ONTBarcodeDemuxGenotypingError {
            if case .processFailed = error { XCTFail("A launch failure is not a samtools failure") }
        } catch {
        }
        XCTAssertEqual(fixture.calls(), [])
    }
}
