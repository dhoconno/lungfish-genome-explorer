// BlastResultArchiveCancelTests.swift - A cancelled task stops the unzip of a BLAST result archive
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishCore

/// ``BlastService`` unpacks a ZIP response with the real `/usr/bin/unzip`. A task cancelled before the
/// unpack launches nothing, and one cancelled during it stops the unzip, and both end with
/// `CancellationError` and leave no extracted files behind.
final class BlastResultArchiveCancelTests: XCTestCase {
    private var tempDir: URL!
    private var service: BlastService!

    override func setUp() async throws {
        tempDir = try TestTempDirectory.make(prefix: "blast-archive-cancel")
        service = BlastService(httpClient: MockHTTPClient())
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(tempDir)
    }

    /// An archive with one 512 MiB member that compresses to 2 MB. Unzip needs about a second and a
    /// half to write it out.
    private func makeLargeArchive() async throws -> Data {
        let member = tempDir.appendingPathComponent("RID_1.json")
        FileManager.default.createFile(atPath: member.path, contents: nil)
        let handle = try FileHandle(forWritingTo: member)
        try handle.truncate(atOffset: 512 * 1_048_576)
        try handle.close()
        let archive = tempDir.appendingPathComponent("large.zip")
        try await SystemToolProbe.run("zip", ["-q", "-1", "-j", archive.path, member.path])
        try FileManager.default.removeItem(at: member)
        return try Data(contentsOf: archive)
    }

    func testATaskCancelledBeforeTheExtractionLaunchesNoUnzip() async throws {
        let archive = try await BlastSystemToolFixtures.resultArchive(in: tempDir)
        let service = try XCTUnwrap(service)
        let task = Task {
            // Wait, without suspending on a cancellable sleep, until the cancel below is visible.
            while !Task.isCancelled { await Task.yield() }
            return try await service.decompressZIPResponse(archive)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A task cancelled before the extraction must not extract")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let unzips = await SystemToolProbe.childPIDs(commandLineHolding: "unzip -o -q")
        XCTAssertTrue(unzips.isEmpty, "unzip was launched for a cancelled task")
    }

    func testCancellingTheExtractionStopsUnzip() async throws {
        let archive = try await makeLargeArchive()
        let service = try XCTUnwrap(service)
        let task = Task { try await service.decompressZIPResponse(archive) }
        let started = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(5)) {
            let pids = await SystemToolProbe.childPIDs(commandLineHolding: "unzip -o -q")
            return !pids.isEmpty
        }
        XCTAssertTrue(started, "unzip never started")

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("The cancelled extraction ran to its end")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(clock.now - cancelledAt, .seconds(10), "The cancelled extraction took too long to end")

        let gone = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(20)) {
            let pids = await SystemToolProbe.childPIDs(commandLineHolding: "unzip -o -q")
            return pids.isEmpty
        }
        XCTAssertTrue(gone, "unzip outlived the cancelled extraction")
    }
}
