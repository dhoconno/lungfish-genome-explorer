// DurableReplaceStreamingDurabilityTests.swift - A streamed publication holds a whole old or new file at every step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Synchronization
import XCTest
import LungfishTestSupport
@testable import LungfishCore

/// `DurableReplace.replace(named:in:writing:)` publishes bytes that a caller
/// streams into the stage file, for a file too large to hold in memory
/// (Phase 2.9 row 259). It shares every step of the `Data` form, so the name
/// holds a complete old or new file throughout, and a failed write is a thrown
/// error. Under `exfat-tests.sh --simulate` every swap takes the ExFAT
/// rotation.
final class DurableReplaceStreamingDurabilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "durable-streaming")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testStreamedChunksPublishAsOneFileAndNothingElseRemains() throws {
        let publication = try DurableReplace.replace(named: "joined.fastq", in: root) { stage in
            try stage.write(Data("alpha\n".utf8))
            try Data("beta\n".utf8).withUnsafeBytes { try stage.write($0) }
            try stage.write(Data())
        }

        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("joined.fastq"), encoding: .utf8), "alpha\nbeta\n")
        XCTAssertEqual(publication.url.lastPathComponent, "joined.fastq")
        XCTAssertNil(publication.retiredURL, "the name held nothing")
        XCTAssertEqual(try entries(), ["joined.fastq"])
    }

    func testAStreamedReplacementSwapsOverTheOldFileEvenOnSimulatedExFAT() throws {
        try Data("old\n".utf8).write(to: root.appendingPathComponent("joined.fastq"))

        _ = try PortableRename.simulatingUnsupportedFlags {
            try DurableReplace.replace(named: "joined.fastq", in: root) { stage in
                try stage.write(Data("new\n".utf8))
            }
        }

        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("joined.fastq"), encoding: .utf8), "new\n")
        XCTAssertEqual(try entries(), ["joined.fastq"])
    }

    func testAThrowingBodyKeepsTheOldFileAndRemovesTheStage() throws {
        let name = root.appendingPathComponent("joined.fastq")
        try Data("old\n".utf8).write(to: name)

        XCTAssertThrowsError(
            try DurableReplace.replace(named: "joined.fastq", in: root) { stage in
                try stage.write(Data("partial".utf8))
                throw Refusal()
            }
        ) { XCTAssertTrue($0 is Refusal) }

        XCTAssertEqual(try String(contentsOf: name, encoding: .utf8), "old\n")
        XCTAssertEqual(try entries(), ["joined.fastq"])
    }

    func testAFullDiskIsAThrownErrorAndTheNameKeepsItsOldFile() throws {
        let name = root.appendingPathComponent("joined.fastq")
        try Data("old\n".utf8).write(to: name)
        let tally = Tally()
        let operations = DurableReplace.Operations(writeBytes: { descriptor, bytes, count in
            if tally.add() == 2 {
                errno = ENOSPC
                return -1
            }
            return Darwin.write(descriptor, bytes, count)
        })

        XCTAssertThrowsError(
            try DurableReplace.$overrideOperations.withValue(operations) {
                try DurableReplace.replace(named: "joined.fastq", in: root) { stage in
                    try stage.write(Data("first chunk\n".utf8))
                    try stage.write(Data("second chunk\n".utf8))
                    XCTFail("the write after the failure must not run")
                }
            }
        ) { error in
            guard case .systemFailure(_, let operation, let code)? = error as? DurableReplace.ReplaceError else {
                return XCTFail("expected a system failure, got \(error)")
            }
            XCTAssertEqual(operation, "write the stage file")
            XCTAssertEqual(code, ENOSPC)
        }

        XCTAssertEqual(try String(contentsOf: name, encoding: .utf8), "old\n")
        XCTAssertEqual(try entries(), ["joined.fastq"])
    }

    func testAnInterruptedWriteIsRetriedAndAShortWriteContinues() throws {
        let tally = Tally()
        let operations = DurableReplace.Operations(writeBytes: { descriptor, bytes, count in
            switch tally.add() {
            case 1:
                errno = EINTR
                return -1
            default:
                return Darwin.write(descriptor, bytes, min(count, 3))
            }
        })

        _ = try DurableReplace.$overrideOperations.withValue(operations) {
            try DurableReplace.replace(named: "joined.fastq", in: root) { stage in
                try stage.write(Data("0123456789\n".utf8))
            }
        }

        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("joined.fastq"), encoding: .utf8), "0123456789\n")
        XCTAssertGreaterThan(tally.count, 4, "the 11 bytes went out in pieces of at most 3 after the retry")
    }

    func testAZeroLengthWriteIsAnErrorNotALoop() throws {
        let operations = DurableReplace.Operations(writeBytes: { _, _, _ in 0 })

        XCTAssertThrowsError(
            try DurableReplace.$overrideOperations.withValue(operations) {
                try DurableReplace.replace(named: "joined.fastq", in: root) { stage in
                    try stage.write(Data("x".utf8))
                }
            }
        ) { error in
            guard case .systemFailure(_, _, let code)? = error as? DurableReplace.ReplaceError else {
                return XCTFail("expected a system failure, got \(error)")
            }
            XCTAssertEqual(code, EIO)
        }
        XCTAssertEqual(try entries(), [])
    }

    func testTheStreamedFormSharesTheDataFormsFaultSteps() throws {
        for step in DurableReplace.Step.allCases {
            let operations = DurableReplace.Operations(checkpoint: { reached in
                if reached == step { throw Refusal() }
            })

            XCTAssertThrowsError(
                try DurableReplace.$overrideOperations.withValue(operations) {
                    try DurableReplace.replace(named: "joined.fastq", in: root) { stage in
                        try stage.write(Data("bytes\n".utf8))
                    }
                },
                "\(step)"
            ) { XCTAssertTrue($0 is Refusal, "\(step)") }

            // Before acceptance the name stays empty. From `observed` on the new file stays.
            let accepted: Set<DurableReplace.Step> = [.observed, .retiredRemoved, .flushed]
            XCTAssertEqual(try entries(), accepted.contains(step) ? ["joined.fastq"] : [], "\(step)")
            try? FileManager.default.removeItem(at: root.appendingPathComponent("joined.fastq"))
        }
    }

    // MARK: - Helpers

    private struct Refusal: Error {}

    private final class Tally: Sendable {
        private let value = Mutex(0)

        @discardableResult
        func add() -> Int { value.withLock { $0 += 1; return $0 } }

        var count: Int { value.withLock { $0 } }
    }

    private func entries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix("._") }
            .sorted()
    }
}
