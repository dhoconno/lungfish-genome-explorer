// ToolProcessPipelineTests.swift - Connected stages of ToolProcess.runPipeline
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore
import LungfishTestSupport

final class ToolProcessPipelineTests: XCTestCase {
    private typealias Fixtures = ToolProcessFixtures

    private func tool(_ path: String, _ arguments: [String] = [], label: String? = nil) -> ToolProcessSpec {
        ToolProcessSpec(
            executableURL: URL(fileURLWithPath: path),
            arguments: arguments,
            environment: ["PATH": Fixtures.systemPath],
            terminationGracePeriod: .milliseconds(200),
            label: label
        )
    }

    /// Far more than a pipe buffer flows between the stages, as it does
    /// between samtools view and samtools sort.
    func testTwoStagesPassLargeDataThrough() async throws {
        let result = try await ToolProcess.runPipeline(
            [
                Fixtures.shell("yes 'ACGTACGTACGTACGTACGT' | head -n 200000", label: "produce"),
                tool("/usr/bin/wc", ["-l"], label: "count"),
            ],
            timeout: .seconds(60)
        )
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.stages.map(\.label), ["produce", "count"])
        XCTAssertEqual(result.stages[1].stdoutText.trimmingCharacters(in: .whitespaces), "200000\n")
        XCTAssertTrue(result.stages[0].stdout.isEmpty, "an inner stage's stdout belongs to the next stage")
        XCTAssertGreaterThan(result.wallTime, .zero)
    }

    func testFailingMiddleStageIsReportedAndDoesNotHangWhenRunToCompletion() async throws {
        let result = try await ToolProcess.runPipeline(
            [
                Fixtures.shell("yes | head -n 100000", label: "first"),
                Fixtures.shell("head -n 2; echo boom >&2; exit 7", label: "middle"),
                tool("/bin/cat", label: "last"),
            ],
            timeout: .seconds(60),
            failurePolicy: .runToCompletion
        )
        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.failedStageIndices.contains(1))
        XCTAssertTrue(result.stages.allSatisfy { $0.stop == nil })
        XCTAssertEqual(result.stages[1].termination, .exited(code: 7))
        XCTAssertEqual(result.stages[1].stderrText, "boom\n")
        XCTAssertEqual(result.stages[2].termination, .exited(code: 0))
        XCTAssertEqual(result.stages[2].stdoutText, "y\ny\n")
    }

    func testFirstStageReadsStdinDataAndLastStageWritesAFile() async throws {
        let directory = try makeToolProcessTempDirectory()
        let output = directory.appendingPathComponent("sorted.txt")
        var first = tool("/bin/cat", label: "cat")
        first.stdin = .data(Data("delta\nalpha\ncharlie\nbravo\n".utf8))
        var last = tool("/usr/bin/sort", label: "sort")
        last.stdout = .file(output)
        let result = try await ToolProcess.runPipeline([first, last], timeout: .seconds(30))
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "alpha\nbravo\ncharlie\ndelta\n")
    }

    func testEventsCarryTheirStageIndex() async throws {
        let events = ToolProcessEventLog()
        let result = try await ToolProcess.runPipeline(
            [
                Fixtures.shell("echo from-first >&2; echo payload", label: "first"),
                Fixtures.shell("cat; echo from-second >&2", label: "second"),
            ]
        ) { stage, event in events.append(stage: stage, event) }
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(events.lines(.stderr, stage: 0), ["from-first"])
        XCTAssertEqual(events.lines(.stderr, stage: 1), ["from-second"])
        XCTAssertEqual(events.lines(.stdout, stage: 1), ["payload"])
        XCTAssertEqual(events.lines(.stdout, stage: 0), [])
        let startedStages = events.all.compactMap { entry -> Int? in
            if case .started = entry.event { return entry.stage }
            return nil
        }
        XCTAssertEqual(startedStages.sorted(), [0, 1])
    }

    func testTimeoutTerminatesEveryStage() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await ToolProcess.runPipeline(
                [Fixtures.shell("sleep 30", label: "slow"), tool("/bin/cat", label: "cat")],
                timeout: .milliseconds(500)
            )
            XCTFail("Expected a timeout")
        } catch ToolProcessError.timedOut(let timeout, let results) {
            XCTAssertEqual(timeout, .wallClock(.milliseconds(500)))
            XCTAssertEqual(results.count, 2)
            XCTAssertEqual(results[0].stop, .timedOut(.wallClock(.milliseconds(500))))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(10))
    }

    func testCancellationTerminatesEveryStage() async throws {
        let directory = try makeToolProcessTempDirectory()
        let firstPID = directory.appendingPathComponent("first.pid")
        let secondPID = directory.appendingPathComponent("second.pid")
        let stages = [
            Fixtures.shell("echo $$ > \(Fixtures.shellQuote(firstPID.path)); while true; do sleep 1; done", label: "first"),
            Fixtures.shell("echo $$ > \(Fixtures.shellQuote(secondPID.path)); while true; do sleep 1; done", label: "second"),
        ]
        let task = Task { try await ToolProcess.runPipeline(stages) }
        let first = await Fixtures.waitForPID(firstPID)
        let second = await Fixtures.waitForPID(secondPID)
        defer {
            Fixtures.killIfAlive(first)
            Fixtures.killIfAlive(second)
        }
        task.cancel()
        switch await task.result {
        case .failure(ToolProcessError.cancelled(let results)):
            XCTAssertEqual(results.map(\.stop), [.cancelled, .cancelled])
        default:
            XCTFail("Expected cancelled")
        }
        let firstExited = await Fixtures.waitForExit(try XCTUnwrap(first))
        let secondExited = await Fixtures.waitForExit(try XCTUnwrap(second))
        XCTAssertTrue(firstExited)
        XCTAssertTrue(secondExited)
    }

    func testALaterStageThatCannotLaunchStopsTheEarlierOnes() async throws {
        let directory = try makeToolProcessTempDirectory()
        let firstPID = directory.appendingPathComponent("first.pid")
        do {
            _ = try await ToolProcess.runPipeline(
                [
                    Fixtures.shell("echo $$ > \(Fixtures.shellQuote(firstPID.path)); while true; do sleep 1; done", label: "first"),
                    tool("/nonexistent/lungfish-\(UUID().uuidString)", label: "ghost"),
                ],
                timeout: .seconds(30)
            )
            XCTFail("Expected launchFailed")
        } catch ToolProcessError.launchFailed(let label, _, let results) {
            XCTAssertEqual(label, "ghost")
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results.first?.label, "first")
            XCTAssertEqual(results.first?.stop, .pipelineStageFailed(stage: 1))
            if let pid = results.first?.pid {
                XCTAssertFalse(ProcessTreeTerminator.processExists(pid: pid))
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testConflictingStageWiringIsRejectedBeforeLaunch() async throws {
        var reading = tool("/bin/cat")
        reading.stdin = .data(Data("x".utf8))
        var writing = tool("/bin/cat")
        writing.stdout = .discard
        var limited = tool("/bin/cat")
        limited.timeout = .seconds(5)
        let invalid: [[ToolProcessSpec]] = [
            [],
            [tool("/bin/cat"), reading],
            [writing, tool("/bin/cat")],
            [limited, tool("/bin/cat")],
        ]
        for stages in invalid {
            do {
                _ = try await ToolProcess.runPipeline(stages)
                XCTFail("Expected invalidSpec for \(stages.map(\.label))")
            } catch ToolProcessError.invalidSpec {
            } catch {
                XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testSingleStagePipelineMatchesRun() async throws {
        let result = try await ToolProcess.runPipeline([Fixtures.shell("echo solo; exit 2")])
        XCTAssertEqual(result.stages.count, 1)
        XCTAssertEqual(result.stages[0].termination, .exited(code: 2))
        XCTAssertEqual(result.stages[0].stdoutText, "solo\n")
        XCTAssertEqual(result.failedStageIndices, [0])
    }
}
