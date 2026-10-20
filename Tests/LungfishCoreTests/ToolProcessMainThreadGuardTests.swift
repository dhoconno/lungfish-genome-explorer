// ToolProcessMainThreadGuardTests.swift - The debug trap of a blocking ToolProcess call on the main thread
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

#if DEBUG
import Foundation
import Synchronization
import Testing
import XCTest
@testable import LungfishCore

/// Phase 2.13 lane 13.05 M3 (SWIFT ruling on M3, vote V2-3). The recorder stands in for the trap, so each test reads
/// which blocking call the guard caught. A test process is never armed, because XCTest runs a synchronous test
/// method on the main thread (`ToolProcessMainQueueMeasureTests`). These stay XCTest methods, since the recorder is
/// process state and Swift Testing runs its tests in parallel in one process.
final class ToolProcessMainThreadGuardTests: XCTestCase {
    /// The names the guard caught, in order.
    private final class Recorded: Sendable {
        private let names = Mutex<[String]>([])

        func append(_ name: String) {
            names.withLock { $0.append(name) }
        }

        var all: [String] {
            names.withLock { $0 }
        }
    }

    private static let everyBlockingCall: Set<String> = [
        "runBlocking", "ToolProcessRun.waitBlocking", "ToolPipelineRun.waitBlocking", "read(upTo:)", "writeBlocking",
    ]

    private static func spec(
        _ path: String,
        _ arguments: [String] = [],
        label: String,
        stdin: ToolProcessInput = .null,
        stdout: ToolProcessOutput = .capture(),
        timeout: Duration? = nil
    ) -> ToolProcessSpec {
        ToolProcessSpec(
            executableURL: URL(fileURLWithPath: path),
            arguments: arguments,
            environment: ["PATH": ToolProcessFixtures.systemPath],
            stdin: stdin,
            stdout: stdout,
            timeout: timeout,
            terminationGracePeriod: .milliseconds(200),
            label: label
        )
    }

    private static func readToEnd(_ stdout: ToolProcessOutputStream) -> Data {
        var bytes = Data()
        while true {
            let chunk = stdout.read(upTo: 16)
            if chunk.isEmpty { return bytes }
            bytes.append(chunk)
        }
    }

    /// Each of the five blocking calls once on the calling thread. Returns, for `runBlocking`, the single run and the
    /// pipeline, whether the run succeeded and gave back what it was fed.
    private static func callEveryBlockingCall() throws -> [Bool] {
        let echoed = try ToolProcess.runBlocking(spec("/bin/echo", ["guard"], label: "echo", timeout: .seconds(30)))

        let single = try ToolProcess.start(
            spec("/bin/cat", label: "cat", stdin: .stream, stdout: .stream, timeout: .seconds(30))
        )
        try single.stdin.writeBlocking(Data("x".utf8))
        single.stdin.close()
        let singleBytes = readToEnd(single.stdout)
        let singleResult = try single.waitBlocking()

        let pipeline = try ToolProcess.startPipeline(
            [spec("/bin/cat", label: "first", stdin: .stream), spec("/bin/cat", label: "last", stdout: .stream)],
            timeout: .seconds(30)
        )
        try pipeline.stdin.writeBlocking(Data("y".utf8))
        pipeline.stdin.close()
        let pipelineBytes = readToEnd(pipeline.stdout)
        let pipelineResult = try pipeline.waitBlocking()

        return [
            echoed.isSuccess && echoed.stdout == Data("guard\n".utf8),
            singleResult.isSuccess && singleBytes == Data("x".utf8),
            pipelineResult.isSuccess && pipelineBytes == Data("y".utf8),
        ]
    }

    /// On the main thread the guard catches all five calls, and with the recorder in place of the trap every call
    /// still works.
    func testEachBlockingCallIsCaughtOnTheMainThread() throws {
        XCTAssertTrue(Thread.isMainThread)
        let recorded = Recorded()
        ToolProcessMainThreadGuard.record(into: { recorded.append($0) })
        defer { ToolProcessMainThreadGuard.record(into: nil) }

        let succeeded = try Self.callEveryBlockingCall()

        XCTAssertEqual(Set(recorded.all), Self.everyBlockingCall)
        XCTAssertEqual(succeeded, [true, true, true])
    }

    /// Off the main thread, in an async test method's own task, the guard catches nothing.
    func testNoBlockingCallIsCaughtOffTheMainThread() async throws {
        let recorded = Recorded()
        ToolProcessMainThreadGuard.record(into: { recorded.append($0) })
        defer { ToolProcessMainThreadGuard.record(into: nil) }

        let succeeded = try Self.callEveryBlockingCall()

        XCTAssertEqual(recorded.all, [])
        XCTAssertEqual(succeeded, [true, true, true])
    }

    /// With no recorder, an unarmed guard lets a main-thread call run, which shows that a test process is never armed.
    func testAnUnarmedGuardLetsAMainThreadCallRun() throws {
        XCTAssertTrue(Thread.isMainThread)
        let result = try ToolProcess.runBlocking(Self.spec("/bin/echo", ["unarmed"], label: "echo", timeout: .seconds(30)))
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.stdout, Data("unarmed\n".utf8))
    }
}

/// The armed trap itself, in a child process, so the test process stays unarmed (QA rider 1 of vote V2-3). The
/// unarmed control shows that the failure comes from arming and not from the child.
struct ToolProcessMainThreadGuardExitTests {
    @Test func anArmedGuardStopsABlockingCallOnTheMainThread() async {
        await #expect(processExitsWith: .failure) {
            ToolProcessMainThreadGuard.arm()
            await MainActor.run {
                _ = try? ToolProcess.runBlocking(ToolProcessSpec(
                    executableURL: URL(fileURLWithPath: "/bin/echo"),
                    arguments: ["armed"],
                    environment: ["PATH": "/usr/bin:/bin"],
                    timeout: .seconds(30)
                ))
            }
        }
    }

    @Test func anUnarmedChildRunsTheSameCall() async {
        await #expect(processExitsWith: .success) {
            await MainActor.run {
                _ = try? ToolProcess.runBlocking(ToolProcessSpec(
                    executableURL: URL(fileURLWithPath: "/bin/echo"),
                    arguments: ["unarmed"],
                    environment: ["PATH": "/usr/bin:/bin"],
                    timeout: .seconds(30)
                ))
            }
        }
    }
}
#endif
