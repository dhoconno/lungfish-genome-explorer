// BBToolsPairArgumentsRunTests.swift - The removal logic of the shared reformat split, with a fake runner
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishPortable

/// QA review of lane READLAYOUT, should-fix 1. `BBToolsPairArguments.runDeinterleave` is the one code in the range that
/// deletes files. It is generic over the run, so these tests start no tool. A plain FASTQ needs no child process, so the
/// launcher fails a test that uses it.
final class BBToolsPairArgumentsRunTests: XCTestCase {

    private typealias Outcome = (exit: Int, words: String)

    private struct NoChildLauncher: PortableChildLauncher {
        func start(_ request: PortableChildRequest) throws -> any PortableChild {
            XCTFail("a plain FASTQ needs no child process")
            throw CocoaError(.featureUnsupported)
        }
    }

    private static let namesRefusal = "java.lang.RuntimeException: Names are not paired."

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbtools-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func records(_ headers: [String]) throws -> URL {
        let url = root.appendingPathComponent("in-\(UUID().uuidString).fastq")
        try headers.map { "@\($0)\nACGT\n+\nIIII\n" }.joined().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func split(
        _ input: URL,
        _ out1: URL,
        _ out2: URL,
        tool: ([String]) throws -> Outcome
    ) async throws -> (outcome: Outcome, arguments: [String]) {
        try await BBToolsPairArguments.runDeinterleave(
            input: input.path, out1: out1.path, out2: out2.path, launcher: NoChildLauncher(),
            run: { try tool($0) },
            failureWords: { $0.exit == 0 ? nil : $0.words }
        )
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func write(_ text: String, to url: URL, modified: Date? = nil) throws {
        try text.write(to: url, atomically: false, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    func testFailureRemovesWhatTheRunWroteAndKeepsWhatItDidNot() async throws {
        let out1 = root.appendingPathComponent("r1.fastq"), out2 = root.appendingPathComponent("r2.fastq")
        try write("keep", to: out1, modified: Date(timeIntervalSinceNow: -3_600))
        var calls = 0

        let result = try await split(try records(["p/1", "p/2"]), out1, out2) { _ in
            calls += 1
            try self.write("partial", to: out2)
            return (1, "boom")
        }

        XCTAssertEqual(result.outcome.exit, 1)
        XCTAssertEqual(result.outcome.words, "boom")
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(exists(out2), "what the run wrote is removed")
        XCTAssertEqual(try String(contentsOf: out1, encoding: .utf8), "keep", "what the run left alone stays")
    }

    func testARunThatRewroteAnExistingOutputHasItRemoved() async throws {
        let out1 = root.appendingPathComponent("r1.fastq"), out2 = root.appendingPathComponent("r2.fastq")
        try write("old", to: out1, modified: Date(timeIntervalSinceNow: -3_600))

        _ = try await split(try records(["p/1", "p/2"]), out1, out2) { _ in
            try self.write("0123456789", to: out1)
            return (1, "boom")
        }

        XCTAssertFalse(exists(out1))
    }

    /// A tool that rewrites an output with as many bytes inside the same second leaves the same size and the same
    /// whole-second date. The stamp must still tell the two files apart.
    func testARewriteOfTheSameSizeInTheSameSecondIsStillSeen() async throws {
        let out1 = root.appendingPathComponent("r1.fastq"), out2 = root.appendingPathComponent("r2.fastq")
        let second = Date.timeIntervalSinceReferenceDate.rounded(.down) - 3_600
        try write("aaaa", to: out1, modified: Date(timeIntervalSinceReferenceDate: second))

        _ = try await split(try records(["p/1", "p/2"]), out1, out2) { _ in
            try self.write("bbbb", to: out1, modified: Date(timeIntervalSinceReferenceDate: second + 0.5))
            return (1, "boom")
        }

        XCTAssertFalse(exists(out1))
    }

    func testNamesRefusalOfATrueDottedPairRunsAgainWithoutVint() async throws {
        let out1 = root.appendingPathComponent("r1.fastq"), out2 = root.appendingPathComponent("r2.fastq")
        var argvs: [[String]] = []

        let result = try await split(try records(["SRR1.1.1", "SRR1.1.2", "SRR1.2.1", "SRR1.2.2"]), out1, out2) { argv in
            argvs.append(argv)
            if argv.contains("vint=t") { return (1, Self.namesRefusal) }
            try self.write("r1", to: out1)
            try self.write("r2", to: out2)
            return (0, "")
        }

        XCTAssertEqual(argvs.count, 2)
        XCTAssertTrue(argvs.first?.contains("vint=t") ?? false)
        XCTAssertFalse(argvs.last?.contains("vint=t") ?? true)
        XCTAssertEqual(result.arguments, argvs.last)
        XCTAssertEqual(result.outcome.exit, 0)
        XCTAssertTrue(exists(out1))
        XCTAssertTrue(exists(out2))
    }

    func testNamesRefusalOfAFalsePairThrowsAndLeavesNothing() async throws {
        let out1 = root.appendingPathComponent("r1.fastq"), out2 = root.appendingPathComponent("r2.fastq")
        var calls = 0

        do {
            _ = try await split(try records(["p0/1", "p0/2", "m0", "m1"]), out1, out2) { _ in
                calls += 1
                try self.write("partial", to: out1)
                try self.write("partial", to: out2)
                return (1, Self.namesRefusal)
            }
            XCTFail("a false pair must stop the split")
        } catch FASTQPairInterleaver.InterleaveError.mateNameMismatch(let recordNumber, _, _, _, _) {
            XCTAssertEqual(recordNumber, 2)
        }

        XCTAssertEqual(calls, 1)
        XCTAssertFalse(exists(out1))
        XCTAssertFalse(exists(out2))
    }

    func testAThrownRunRemovesItsPartialOutputsAndRethrows() async throws {
        let out1 = root.appendingPathComponent("r1.fastq"), out2 = root.appendingPathComponent("r2.fastq")

        do {
            _ = try await split(try records(["p/1", "p/2"]), out1, out2) { _ in
                try self.write("partial", to: out1)
                throw CancellationError()
            }
            XCTFail("the cancel must reach the caller")
        } catch is CancellationError {
            // Rethrown as it came.
        }

        XCTAssertFalse(exists(out1))
    }
}
