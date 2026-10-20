// ToolProcessPipelineStreamTests.swift - startPipeline with a caller-fed first stdin and a raw last stdout
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore
import LungfishTestSupport

/// Phase 2.13 lane 13.05. A pipeline that Swift feeds and reads, with the
/// pipeline's limits, failure policy and cancel covering every stage.
final class ToolProcessPipelineStreamTests: XCTestCase {
    private typealias Fixtures = ToolProcessFixtures

    private static let chunk = 256 * 1024

    private func tool(
        _ path: String,
        _ arguments: [String] = [],
        label: String,
        stdin: ToolProcessInput = .null,
        stdout: ToolProcessOutput = .capture()
    ) -> ToolProcessSpec {
        ToolProcessSpec(
            executableURL: URL(fileURLWithPath: path),
            arguments: arguments,
            environment: ["PATH": Fixtures.systemPath],
            stdin: stdin,
            stdout: stdout,
            terminationGracePeriod: .milliseconds(200),
            label: label
        )
    }

    private func catThroughCat() throws -> ToolPipelineRun {
        try ToolProcess.startPipeline(
            [tool("/bin/cat", label: "first", stdin: .stream), tool("/bin/cat", label: "last", stdout: .stream)],
            timeout: .seconds(120)
        )
    }

    /// 8 MB through two stages, written by the caller with async writes and
    /// read raw, arrive byte for byte.
    func testCallerFedPipelineIsReadRawByteExact() async throws {
        let input = ToolProcessStreamTests.pseudoRandomBytes(count: 8 * 1024 * 1024)
        let run = try catThroughCat()
        let stdin = run.stdin
        let feed = Task {
            for offset in stride(from: 0, to: input.count, by: Self.chunk) {
                try await stdin.write(input.subdata(in: offset..<min(offset + Self.chunk, input.count)))
            }
            stdin.close()
        }
        let bytes = await run.stdout.drain(Data()) { collected, chunk in
            collected.append(chunk)
            return true
        }
        try await feed.value
        let result = try await run.result()

        XCTAssertEqual(bytes, input)
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.stages.map(\.label), ["first", "last"])
        XCTAssertTrue(result.stages[1].stdout.isEmpty, "a streamed stdout keeps no bytes in the result")
        XCTAssertEqual(run.pids.compactMap { $0 }, result.stages.map(\.pid))
    }

    /// A reader that pauses holds the whole pipeline back, down to the
    /// caller's blocking writes, and every byte still arrives.
    func testSlowReaderHoldsTheCallerBack() throws {
        let input = ToolProcessStreamTests.pseudoRandomBytes(count: 8 * 1024 * 1024)
        let run = try catThroughCat()
        let writeError = ToolProcessTestBox<ToolProcessInputStream.WriteError?>(nil)
        let writerDone = DispatchSemaphore(value: 0)
        DispatchQueue(label: "pipeline-writer").async {
            do throws(ToolProcessInputStream.WriteError) {
                for offset in stride(from: 0, to: input.count, by: Self.chunk) {
                    try run.stdin.writeBlocking(input.subdata(in: offset..<min(offset + Self.chunk, input.count)))
                }
            } catch {
                writeError.withLock { $0 = error }
            }
            run.stdin.close()
            writerDone.signal()
        }
        var bytes = run.stdout.read(upTo: 64 * 1024)
        usleep(400_000)
        XCTAssertEqual(writerDone.wait(timeout: .now()), .timedOut, "the writer must be held back while the reader pauses")
        var chunks = 0
        while true {
            let chunk = run.stdout.read(upTo: 64 * 1024)
            if chunk.isEmpty { break }
            bytes.append(chunk)
            chunks += 1
            if chunks % 16 == 0 {
                usleep(1_000)
            }
        }
        XCTAssertEqual(writerDone.wait(timeout: .now() + 30), .success)
        let result = try run.waitBlocking()

        XCTAssertNil(writeError.withLock { $0 })
        XCTAssertEqual(bytes, input)
        XCTAssertTrue(result.isSuccess)
    }

    /// The last stage exits after five bytes. The first stage then dies of
    /// SIGPIPE, which does not count because the stage it fed finished
    /// cleanly, and the caller's write ends with readerGone.
    func testLastStageThatExitsEarlyEndsTheFeedAndItsFeedersSIGPIPEDoesNotCount() async throws {
        let run = try ToolProcess.startPipeline(
            [tool("/bin/cat", label: "first", stdin: .stream), tool("/usr/bin/head", ["-c", "5"], label: "last", stdout: .stream)],
            timeout: .seconds(60)
        )
        let stdin = run.stdin
        let feed = Task { () -> ToolProcessInputStream.WriteError? in
            do throws(ToolProcessInputStream.WriteError) {
                for _ in 0..<64 {
                    try await stdin.write(Data(repeating: UInt8(ascii: "x"), count: 1024 * 1024))
                }
                return nil
            } catch {
                return error
            }
        }
        let bytes = await run.stdout.drain(Data()) { collected, chunk in
            collected.append(chunk)
            return true
        }
        let writeError = await feed.value
        stdin.close()
        let result = try await run.result()

        XCTAssertEqual(bytes, Data("xxxxx".utf8))
        XCTAssertEqual(writeError, .readerGone)
        XCTAssertEqual(result.stages[0].termination, .signaled(signal: SIGPIPE))
        XCTAssertEqual(result.stages[1].termination, .exited(code: 0))
        XCTAssertEqual(result.failedStageIndices, [])
        XCTAssertTrue(result.stages.allSatisfy { $0.stop == nil })
        XCTAssertTrue(result.isSuccess)
    }

    /// A cancel while the caller's write waits on full pipes and its reader
    /// waits on an empty stream stops every stage and releases both ends.
    func testCancelWithBothEndsOpenStopsEveryStageAndReleasesBoth() throws {
        let run = try ToolProcess.startPipeline(
            [tool("/bin/cat", label: "first", stdin: .stream), tool("/bin/sleep", ["30"], label: "last", stdout: .stream)]
        )
        let writeError = ToolProcessTestBox<ToolProcessInputStream.WriteError?>(nil)
        let readBytes = ToolProcessTestBox(Data("unset".utf8))
        let writerDone = DispatchSemaphore(value: 0)
        let readerDone = DispatchSemaphore(value: 0)
        DispatchQueue(label: "pipeline-writer").async {
            do throws(ToolProcessInputStream.WriteError) {
                try run.stdin.writeBlocking(Data(repeating: UInt8(ascii: "x"), count: 4 * 1024 * 1024))
            } catch {
                writeError.withLock { $0 = error }
            }
            writerDone.signal()
        }
        DispatchQueue(label: "pipeline-reader").async {
            let bytes = ToolProcessStreamTests.readToEnd(run.stdout)
            readBytes.withLock { $0 = bytes }
            readerDone.signal()
        }
        usleep(300_000)
        XCTAssertEqual(writerDone.wait(timeout: .now()), .timedOut, "the write must wait on the full pipes")
        XCTAssertEqual(readerDone.wait(timeout: .now()), .timedOut, "the reader must wait on the empty stream")
        let pids = run.pids.compactMap { $0 }
        XCTAssertEqual(pids.count, 2)

        run.cancel()
        XCTAssertEqual(writerDone.wait(timeout: .now() + 30), .success, "cancel must release the pending writer")
        XCTAssertEqual(readerDone.wait(timeout: .now() + 30), .success, "cancel must end the blocked read")
        XCTAssertEqual(writeError.withLock { $0 }, .readerGone)
        XCTAssertEqual(readBytes.withLock { $0 }, Data())
        do {
            _ = try run.waitBlocking()
            XCTFail("Expected a cancellation")
        } catch .cancelled(let results) {
            XCTAssertEqual(results.map(\.stop), [.cancelled, .cancelled])
        }
        for pid in pids {
            XCTAssertTrue(ToolProcessStdinTests.waitForExit(pid), "stage \(pid) must be gone")
        }
    }

    /// The pipeline's wall-clock limit stops every stage with both ends
    /// open, ends the read, and leaves the writer with no reader.
    func testPipelineLimitStopsEveryStageWithBothEndsOpen() async throws {
        let run = try ToolProcess.startPipeline(
            [tool("/bin/cat", label: "first", stdin: .stream), tool("/bin/cat", label: "last", stdout: .stream)],
            timeout: .milliseconds(500)
        )
        let bytes = await run.stdout.drain(Data()) { collected, chunk in
            collected.append(chunk)
            return true
        }
        XCTAssertEqual(bytes, Data())
        do {
            _ = try await run.result()
            XCTFail("Expected a timeout")
        } catch .timedOut(let timeout, let results) {
            XCTAssertEqual(timeout, .wallClock(.milliseconds(500)))
            XCTAssertEqual(results.map(\.stop), Array(repeating: .timedOut(.wallClock(.milliseconds(500))), count: 2))
        }
        do {
            try await run.stdin.write(Data("late".utf8))
            XCTFail("a write after the run ended must be refused")
        } catch {
            XCTAssertEqual(error, .readerGone)
        }
    }

    /// Only the first stage's stdin and the last stage's stdout can stream.
    func testStartPipelineStreamsOnlyTheFirstStdinAndTheLastStdout() {
        let cases: [(stages: [ToolProcessSpec], words: String)] = [
            ([tool("/bin/cat", label: "middle", stdout: .stream), tool("/bin/cat", label: "cat")],
             "Stage 0 (middle) writes into the next stage, so its stdout must stay at the default."),
            ([tool("/bin/cat", label: "cat"), tool("/bin/cat", label: "later", stdin: .stream)],
             "Stage 1 (later) reads the previous stage's stdout, so its stdin must stay .null."),
        ]
        for (stages, words) in cases {
            do {
                _ = try ToolProcess.startPipeline(stages)
                XCTFail("Expected invalidSpec for \(stages.map(\.label))")
            } catch .invalidSpec(let reason) {
                XCTAssertEqual(reason, words)
            } catch {
                XCTFail("Unexpected error \(error)")
            }
        }
    }
}
