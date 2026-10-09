// ToolProcessIntegrityTests.swift - Byte-exact output, descriptor hygiene and bounded memory in ToolProcess
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Synchronization
import XCTest
@testable import LungfishCore
import LungfishTestSupport

final class ToolProcessIntegrityTests: XCTestCase {
    private typealias Fixtures = ToolProcessFixtures

    private func cat(_ arguments: [String] = [], stdout: ToolProcessOutput = .capture()) -> ToolProcessSpec {
        ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: arguments,
            environment: [:],
            stdout: stdout,
            timeout: .seconds(120)
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func randomFile(bytes count: Int) throws -> (url: URL, digest: String) {
        let directory = try makeToolProcessTempDirectory()
        let url = directory.appendingPathComponent("random.bin")
        var bytes = [UInt8](repeating: 0, count: count)
        arc4random_buf(&bytes, count)
        let data = Data(bytes)
        try data.write(to: url)
        return (url, sha256(data))
    }

    // MARK: - Byte-exact output

    func testFiftyMegabytesOfBinaryOutputAreCapturedByteExact() async throws {
        let source = try randomFile(bytes: 50_000_000)
        let result = try await ToolProcess.run(cat([source.url.path]))
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.stdout.count, 50_000_000)
        XCTAssertEqual(sha256(result.stdout), source.digest)
    }

    func testFiftyMegabytesOfBinaryOutputAreWrittenToAFileByteExact() async throws {
        let source = try randomFile(bytes: 50_000_000)
        let output = source.url.deletingLastPathComponent().appendingPathComponent("copy.bin")
        let result = try await ToolProcess.run(cat([source.url.path], stdout: .file(output)))
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(sha256(try Data(contentsOf: output)), source.digest)
    }

    // MARK: - Descriptors

    private func openDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    /// Waits for the count to return to `baseline`, because the test process
    /// can open descriptors of its own for a moment.
    private func assertDescriptorsReturn(to baseline: Int, _ message: String) async {
        var last = openDescriptorCount()
        let returned = await waitUntil(timeout: .seconds(3), pollInterval: .milliseconds(20)) {
            last = openDescriptorCount()
            return last <= baseline
        }
        XCTAssertTrue(returned, "\(message): \(last) descriptors open, \(baseline) before")
    }

    func testNoDescriptorLeaksAfterSuccessLaunchFailureAndCancellation() async throws {
        // Warm up the code paths, so lazily opened system descriptors are in the baseline.
        _ = try await ToolProcess.run(Fixtures.shell("echo warm; echo up >&2", stdin: .data(Data("x".utf8))))
        let baseline = openDescriptorCount()

        _ = try await ToolProcess.run(Fixtures.shell("cat; echo err >&2", stdin: .data(Data(repeating: 7, count: 200_000))))
        await assertDescriptorsReturn(to: baseline, "after a successful run")

        do {
            _ = try await ToolProcess.run(
                ToolProcessSpec(executableURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"), environment: [:])
            )
            XCTFail("Expected launchFailed")
        } catch ToolProcessError.launchFailed {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        await assertDescriptorsReturn(to: baseline, "after a launch failure")

        let directory = try makeToolProcessTempDirectory()
        let pidFile = directory.appendingPathComponent("root.pid")
        let spec = Fixtures.shell("echo $$ > \(Fixtures.shellQuote(pidFile.path)); while true; do sleep 1; done")
        let task = Task { try await ToolProcess.run(spec) }
        let pid = await Fixtures.waitForPID(pidFile)
        defer { Fixtures.killIfAlive(pid) }
        task.cancel()
        _ = await task.result
        await assertDescriptorsReturn(to: baseline, "after a cancellation")
    }

    // MARK: - Concurrency

    func testThirtyTwoConcurrentRunsAllDrainCompletely() async throws {
        let results = try await withThrowingTaskGroup(of: ToolProcessResult.self) { group in
            for index in 0..<32 {
                group.addTask {
                    try await ToolProcess.run(
                        Fixtures.shell(
                            "yes run\(index) | head -c 200000; echo done-\(index) >&2",
                            timeout: .seconds(120)
                        )
                    )
                }
            }
            var collected: [ToolProcessResult] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }
        XCTAssertEqual(results.count, 32)
        for result in results {
            XCTAssertTrue(result.isSuccess, "\(result.termination) drainTimedOut=\(result.outputDrainTimedOut)")
            XCTAssertFalse(result.outputDrainTimedOut)
            XCTAssertEqual(result.stdout.count, 200_000)
            XCTAssertTrue(result.stderrText.hasPrefix("done-"))
        }
    }

    /// Exits are seen through the process source alone, with no polling, so
    /// a missed exit would never end its run. Short runs started back to
    /// back race their exit against the source's registration.
    func testShortRunsStartedBackToBackAllSeeTheirExit() async throws {
        let count = 200
        let runs = try (0..<count).map { _ in
            try ToolProcess.start(ToolProcessSpec(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                environment: [:],
                stdout: .discard,
                stderr: .discard
            ))
        }
        let ended = expectation(description: "every run ends")
        ended.expectedFulfillmentCount = count
        let clean = ToolProcessTestBox(0)
        for run in runs {
            Task {
                if (try? await run.result())?.termination == .exited(code: 0) {
                    clean.withLock { $0 += 1 }
                }
                ended.fulfill()
            }
        }
        await fulfillment(of: [ended], timeout: 60)
        XCTAssertEqual(clean.withLock { $0 }, count)
    }

    // MARK: - Bounded memory

    private static let noNewlineScript = "head -c 20000000 /dev/zero | tr '\\0' a"

    func testTwentyMegabytesWithoutNewlinesStayWithinTheCaptureLimitUnobserved() async throws {
        let result = try await ToolProcess.run(
            Fixtures.shell(Self.noNewlineScript, stdout: .capture(limit: 1_000_000), timeout: .seconds(120))
        )
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.stdout.count, 1_000_000)
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertTrue(result.stdout.allSatisfy { $0 == 0x61 })
    }

    func testTwentyMegabytesWithoutNewlinesArriveAsBoundedPartialLines() async throws {
        final class LineStats: Sendable {
            let values = Mutex((count: 0, longest: 0, bytes: 0))
        }
        let stats = LineStats()
        let result = try await ToolProcess.run(
            Fixtures.shell(Self.noNewlineScript, stdout: .capture(limit: 1_000_000), timeout: .seconds(120))
        ) { event in
            guard case .output(.stdout, let line) = event else { return }
            stats.values.withLock {
                $0.count += 1
                $0.longest = max($0.longest, line.utf8.count)
                $0.bytes += line.utf8.count
            }
        }
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.stdout.count, 1_000_000)
        let values = stats.values.withLock { $0 }
        XCTAssertLessThanOrEqual(values.longest, ProcessOutputLineFramer.defaultMaxLineBytes)
        XCTAssertGreaterThan(values.count, 300)
        XCTAssertEqual(values.bytes, 20_000_000)
    }
}
