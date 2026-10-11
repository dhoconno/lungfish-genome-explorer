// ToolProcessEntryPointPinTests.swift - Results and errors of each ToolProcess entry point, pinned before the observer hook
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore
import LungfishTestSupport

/// Phase 2.7 lane S1 (B1). The provenance observer hook must leave the result
/// or error of every entry point as it was. The other ToolProcess suites pin
/// most cases for `run`, `runPipeline`, `runBlocking` and `start`. These pin
/// the cases they leave out, a pipeline cancelled before launch, pipelines
/// whose first or middle stage cannot launch, a pipeline's idle limit, the
/// signal, launch failure and limits of `runBlocking`, and a dropped handle
/// whose output is captured.
final class ToolProcessEntryPointPinTests: XCTestCase {
    private typealias Fixtures = ToolProcessFixtures

    // MARK: - runPipeline

    func testPipelineCancelledBeforeLaunchLaunchesNothing() async throws {
        let directory = try makeToolProcessTempDirectory()
        let marker = directory.appendingPathComponent("ran")
        let launched = ToolProcessTestBox<[Int]>([])
        let stages = [
            Fixtures.shell("touch \(Fixtures.shellQuote(marker.path))", label: "first"),
            Self.tool("/bin/cat", label: "second"),
        ]
        let task = Task { () async throws -> ToolPipelineResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ToolProcess.runPipeline(
                stages,
                timeout: .seconds(30),
                onLaunch: { stage, _ in launched.withLock { $0.append(stage) } }
            )
        }
        switch await task.result {
        case .failure(ToolProcessError.cancelled(let results)):
            XCTAssertTrue(results.isEmpty)
        default:
            XCTFail("Expected cancelled with no results")
        }
        XCTAssertEqual(launched.withLock { $0 }, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testPipelineWhoseFirstStageCannotLaunchLaunchesNoOtherStage() async throws {
        let launched = ToolProcessTestBox<[Int]>([])
        do {
            _ = try await ToolProcess.runPipeline(
                [Self.missingTool(label: "ghost"), Self.tool("/bin/cat", label: "second")],
                timeout: .seconds(30),
                onLaunch: { stage, _ in launched.withLock { $0.append(stage) } }
            )
            XCTFail("Expected launchFailed")
        } catch ToolProcessError.launchFailed(let label, _, let results) {
            XCTAssertEqual(label, "ghost")
            XCTAssertTrue(results.isEmpty)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertEqual(launched.withLock { $0 }, [])
    }

    /// The second of three stages cannot launch. The first is stopped on its
    /// account and the third never launches.
    func testPipelineWhoseMiddleStageCannotLaunchStopsTheFirstAndNeverLaunchesTheLast() async throws {
        let launched = ToolProcessTestBox<[Int]>([])
        do {
            _ = try await ToolProcess.runPipeline(
                [
                    Fixtures.shell("while true; do sleep 1; done", label: "first"),
                    Self.missingTool(label: "ghost"),
                    Self.tool("/bin/cat", label: "last"),
                ],
                timeout: .seconds(30),
                onLaunch: { stage, _ in launched.withLock { $0.append(stage) } }
            )
            XCTFail("Expected launchFailed")
        } catch ToolProcessError.launchFailed(let label, _, let results) {
            XCTAssertEqual(label, "ghost")
            XCTAssertEqual(results.map(\.label), ["first"])
            XCTAssertEqual(results.first?.stop, .pipelineStageFailed(stage: 1))
            if let pid = results.first?.pid {
                XCTAssertFalse(ProcessTreeTerminator.processExists(pid: pid))
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertEqual(launched.withLock { $0 }, [0])
    }

    func testPipelineIdleLimitStopsEveryStageWithItsPartialOutput() async throws {
        do {
            _ = try await ToolProcess.runPipeline(
                [Fixtures.shell("echo begun; sleep 30", label: "talk"), Self.tool("/bin/cat", label: "cat")],
                timeout: .seconds(60),
                idleTimeout: .milliseconds(500)
            )
            XCTFail("Expected an idle timeout")
        } catch ToolProcessError.timedOut(let timeout, let results) {
            XCTAssertEqual(timeout, .idle(.milliseconds(500)))
            XCTAssertEqual(results.map(\.label), ["talk", "cat"])
            XCTAssertEqual(results.map(\.stop), Array(repeating: .timedOut(.idle(.milliseconds(500))), count: 2))
            XCTAssertEqual(results.last?.stdoutText, "begun\n")
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    // MARK: - runBlocking

    func testRunBlockingReportsASignalAndThrowsALaunchFailure() throws {
        let signaled = try ToolProcess.runBlocking(Fixtures.shell("kill -KILL $$"))
        XCTAssertEqual(signaled.termination, .signaled(signal: SIGKILL))
        XCTAssertNil(signaled.stop)
        XCTAssertFalse(signaled.isSuccess)
        do {
            _ = try ToolProcess.runBlocking(Self.missingTool(label: "ghost"))
            XCTFail("Expected launchFailed")
        } catch ToolProcessError.launchFailed(let label, _, let results) {
            XCTAssertEqual(label, "ghost")
            XCTAssertTrue(results.isEmpty)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testRunBlockingThrowsTimedOutForTheWallAndIdleLimits() throws {
        do {
            _ = try ToolProcess.runBlocking(Fixtures.shell("echo begun; sleep 30", timeout: .milliseconds(500)))
            XCTFail("Expected a timeout")
        } catch ToolProcessError.timedOut(let timeout, let results) {
            XCTAssertEqual(timeout, .wallClock(.milliseconds(500)))
            XCTAssertEqual(results.map(\.stop), [.timedOut(.wallClock(.milliseconds(500)))])
            XCTAssertEqual(results.first?.stdoutText, "begun\n")
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        do {
            _ = try ToolProcess.runBlocking(
                Fixtures.shell("echo begun; sleep 30", timeout: .seconds(60), idleTimeout: .milliseconds(500))
            )
            XCTFail("Expected an idle timeout")
        } catch ToolProcessError.timedOut(let timeout, let results) {
            XCTAssertEqual(timeout, .idle(.milliseconds(500)))
            XCTAssertEqual(results.map(\.stop), [.timedOut(.idle(.milliseconds(500)))])
            XCTAssertEqual(results.first?.stdoutText, "begun\n")
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    // MARK: - start with a dropped handle

    /// Dropping the handle does not stop a process whose output is captured.
    /// It runs to its end, and the run still reaps it and leaves the registry.
    func testDroppingAHandleWithCapturedOutputLetsTheProcessFinishAndReapsIt() async throws {
        let directory = try makeToolProcessTempDirectory()
        let marker = directory.appendingPathComponent("finished")
        let pid = try Self.startAndDrop(
            Fixtures.shell("echo out; sleep 0.2; echo done > \(Fixtures.shellQuote(marker.path))")
        )
        defer { Fixtures.killIfAlive(pid) }
        let finished = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(20)) {
            FileManager.default.fileExists(atPath: marker.path)
        }
        XCTAssertTrue(finished, "dropping the handle must not stop a process whose output is captured")
        let reaped = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(20)) {
            if case .lost = ToolProcessSpawner.peekExit(pid) { return true }
            return false
        }
        XCTAssertTrue(reaped, "the process of a dropped handle must be reaped")
        let unregistered = await waitUntil(timeout: .seconds(30)) {
            !NativeProcessRegistry.shared.isRegistered(processGroupLeader: pid)
        }
        XCTAssertTrue(unregistered, "a finished run leaves the registry")
    }

    // MARK: - Helpers

    private static func startAndDrop(_ spec: ToolProcessSpec) throws -> Int32 {
        let run = try ToolProcess.start(spec)
        guard let pid = run.pid else { throw ToolProcessError.invalidSpec("\(spec.label) did not launch") }
        return pid
    }

    static func tool(_ path: String, label: String) -> ToolProcessSpec {
        ToolProcessSpec(
            executableURL: URL(fileURLWithPath: path),
            environment: ["PATH": Fixtures.systemPath],
            terminationGracePeriod: .milliseconds(200),
            label: label
        )
    }

    static func missingTool(label: String) -> ToolProcessSpec {
        tool("/nonexistent/lungfish-\(UUID().uuidString)", label: label)
    }
}
