// FASTQPairInterleaverStageWriterDurabilityTests.swift - The interleaver writes into a stage file as it writes into a handle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 2.10 lane S31, the follow-up grant. `FASTQPairInterleaver` wrote
/// only into a `FileHandle`, whose files the callers named before they were
/// whole. The `StageWriter` forms of `interleave`, `interleaveRecordedPair`
/// and `copyRecords` write the same bytes into the stage file of a
/// `DurableReplace` publication, where a failed write is a thrown error.
/// The handle forms stay for their other callers, and
/// `FASTQPairInterleaverTests` still covers them.
///
/// The class name holds `Durability`, so `exfat-tests.sh --simulate` runs it
/// with every rename taking its ExFAT fallback.
final class FASTQPairInterleaverStageWriterDurabilityTests: XCTestCase {
    private typealias Fixtures = ReadWriterFixtures
    private var root: URL!
    private var r1: URL!
    private var r2: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "interleaver-stage-durability")
        r1 = try Fixtures.write(Fixtures.mates(["p1/1", "p2/1", "p3/1"], base: "A"), named: "R1.fastq", in: root)
        r2 = try Fixtures.write(Fixtures.mates(["p1/2", "p2/2", "p3/2"], base: "C"), named: "R2.fastq", in: root)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// The bytes a handle form writes for `body`.
    private func viaHandle<T>(_ body: (FileHandle) throws -> T) throws -> (T, Data) {
        let url = root.appendingPathComponent("handle-\(UUID().uuidString).fastq")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let value = try body(handle)
        try handle.close()
        return (value, try Data(contentsOf: url))
    }

    /// The bytes a stage form publishes for `body`.
    private func viaStage<T>(_ body: (DurableReplace.StageWriter) throws -> T) throws -> (T, Data) {
        let url = root.appendingPathComponent("stage-\(UUID().uuidString).fastq")
        let value = try ReadFileWriters.publish(url, writing: body)
        return (value, try Data(contentsOf: url))
    }

    // MARK: - The same bytes

    func testInterleaveWritesTheSameBytesIntoAStageAsIntoAHandle() throws {
        let (handleCounts, handleBytes) = try viaHandle {
            try FASTQPairInterleaver.interleave(r1: r1, r2: r2, to: $0, requireMates: true)
        }
        let (stageCounts, stageBytes) = try viaStage {
            try FASTQPairInterleaver.interleave(r1: r1, r2: r2, to: $0, requireMates: true)
        }

        XCTAssertEqual(stageBytes, handleBytes)
        XCTAssertEqual(stageCounts, handleCounts)
        XCTAssertEqual(stageCounts.writtenRecords, 6)
    }

    func testInterleaveRecordedPairWritesTheSameBytesIntoAStageAsIntoAHandle() throws {
        let (handleCounts, handleBytes) = try viaHandle {
            try FASTQPairInterleaver.interleaveRecordedPair(r1: r1, r2: r2, to: $0)
        }
        let (stageCounts, stageBytes) = try viaStage {
            try FASTQPairInterleaver.interleaveRecordedPair(r1: r1, r2: r2, to: $0)
        }

        XCTAssertEqual(stageBytes, handleBytes)
        XCTAssertEqual(stageCounts, handleCounts)
        XCTAssertEqual(stageCounts.counts.writtenRecords, 6)
    }

    func testCopyRecordsWritesTheSameBytesIntoAStageAsIntoAHandleAndInspectsEachRecord() throws {
        let headers = Fixtures.Tally()
        let (handleCount, handleBytes) = try viaHandle {
            try FASTQPairInterleaver.copyRecords(of: r1, to: $0) { _, _ in headers.add("handle") }
        }
        let (stageCount, stageBytes) = try viaStage {
            try FASTQPairInterleaver.copyRecords(of: r1, to: $0) { _, _ in headers.add("stage") }
        }

        XCTAssertEqual(stageBytes, handleBytes)
        XCTAssertEqual(stageCount, handleCount)
        XCTAssertEqual(stageCount, 3)
        XCTAssertEqual(headers["stage"], 3, "the inspector sees each record before it is written")
    }

    func testAnInspectorThatRefusesAFileLeavesNoStageFileAndNoName() throws {
        let url = root.appendingPathComponent("refused.fastq")

        XCTAssertThrowsError(
            try ReadFileWriters.publish(url) { stage in
                try FASTQPairInterleaver.copyRecords(of: r1, to: stage) { _, number in
                    if number == 2 { throw Fixtures.Refusal() }
                }
            }
        ) { XCTAssertTrue($0 is Fixtures.Refusal) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(try Fixtures.entries(of: root).contains { $0.contains(DurableReplace.stageInfix) })
    }

    /// The sink flushes every 4 MiB, so a larger file reaches the stage in
    /// more than one write.
    func testAFileLargerThanTheSinkBufferReachesTheStageInSeveralWrites() throws {
        let sequence = String(repeating: "A", count: 100)
        let quality = String(repeating: "I", count: 100)
        let text = (1...25_000).map { "@read\($0)\n\(sequence)\n+\n\(quality)\n" }.joined()
        let big = try Fixtures.write(Data(text.utf8), named: "big.fastq", in: root)
        XCTAssertGreaterThan(try Data(contentsOf: big).count, 4 * 1_048_576)
        let tally = Fixtures.Tally()
        let operations = DurableReplace.Operations(writeBytes: { descriptor, bytes, count in
            if Fixtures.path(of: descriptor).contains(DurableReplace.stageInfix) { tally.add("writes") }
            return Darwin.write(descriptor, bytes, count)
        })

        let (count, bytes) = try DurableReplace.$overrideOperations.withValue(operations) {
            try viaStage { try FASTQPairInterleaver.copyRecords(of: big, to: $0) { _, _ in } }
        }

        XCTAssertEqual(count, 25_000)
        XCTAssertEqual(bytes, try Data(contentsOf: big))
        XCTAssertGreaterThanOrEqual(tally["writes"], 2)
    }

    // MARK: - A full disk

    func testAFullDiskIsAThrownErrorFromEachStageFormAndLeavesNoNameOrStageFile() throws {
        let forms: [(String, (DurableReplace.StageWriter) throws -> Void)] = [
            ("interleave", { _ = try FASTQPairInterleaver.interleave(r1: self.r1, r2: self.r2, to: $0) }),
            ("interleaveRecordedPair", { _ = try FASTQPairInterleaver.interleaveRecordedPair(r1: self.r1, r2: self.r2, to: $0) }),
            ("copyRecords", { _ = try FASTQPairInterleaver.copyRecords(of: self.r1, to: $0) { _, _ in } }),
        ]
        for (name, form) in forms {
            let url = root.appendingPathComponent("\(name).fastq")
            let operations = Fixtures.fullDisk(afterWrites: 0, tally: Fixtures.Tally())

            XCTAssertThrowsError(
                try DurableReplace.$overrideOperations.withValue(operations) {
                    try ReadFileWriters.publish(url, writing: form)
                },
                name
            ) { Fixtures.assertFullDisk($0) }

            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), name)
        }
        XCTAssertEqual(try Fixtures.entries(of: root), ["R1.fastq", "R2.fastq"], "no stage file is left")
    }
}
