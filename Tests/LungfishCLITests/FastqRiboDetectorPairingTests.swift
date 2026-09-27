// FastqRiboDetectorPairingTests.swift - fastq ribodetector keeps interleaved mates together
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// RiboDetector judged every record of an interleaved bundle file alone, so
// an rRNA mate was dropped while its partner survived as an orphan. The
// subcommand now splits a strictly interleaved file into R1/R2, runs
// `ribodetector_cpu -i R1 R2 -o out1 out2`, and interleaves each output
// class again. The fake runner pins the plumbing (whole pairs in, whole
// pairs out, no orphan); the last test runs the installed tool.

import ArgumentParser
import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

final class FastqRiboDetectorPairingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ribodetector-pairing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Stands in for `ribodetector_cpu`: every fragment whose R1 name is in
    /// `ribosomal` goes to the `-r` outputs, the rest to the `-o` outputs,
    /// file by file exactly as the real tool writes them.
    private final class FakeRiboDetector: RiboDetectorToolRunning, @unchecked Sendable {
        private(set) var invocations: [[String]] = []
        let ribosomal: Set<String>
        init(ribosomal: Set<String>) { self.ribosomal = ribosomal }

        func detectVersion() async -> String { "0.3.3-fake" }

        func run(arguments: [String], workingDirectory: URL) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
            invocations.append(arguments)
            let inputs = values(after: "-i", in: arguments)
            let outputs = values(after: "-o", in: arguments)
            let rrna = values(after: "-r", in: arguments)
            // A pair is judged from BOTH mates: classify by fragment key so
            // the decision is the same for R1 and R2 of one fragment.
            for (index, input) in inputs.enumerated() {
                let records = try await InterleavedFASTQFixture.readRecords(at: URL(fileURLWithPath: input))
                var kept = ""
                var removed = ""
                for record in records {
                    let text = "@\(record.identifier)\(record.description.map { " " + $0 } ?? "")\n\(record.sequence)\n+\n\(record.quality.toAscii())\n"
                    if ribosomal.contains(InterleavedFASTQFixture.fragmentKey(record)) {
                        removed += text
                    } else {
                        kept += text
                    }
                }
                try kept.write(to: URL(fileURLWithPath: outputs[index]), atomically: true, encoding: .utf8)
                if index < rrna.count {
                    try removed.write(to: URL(fileURLWithPath: rrna[index]), atomically: true, encoding: .utf8)
                }
            }
            return ("", "", 0)
        }

        private func values(after flag: String, in arguments: [String]) -> [String] {
            guard let start = arguments.firstIndex(of: flag) else { return [] }
            var values: [String] = []
            for argument in arguments[(start + 1)...] {
                if argument.hasPrefix("-") { break }
                values.append(argument)
            }
            return values
        }
    }

    private func withFakeTool<T>(_ fake: FakeRiboDetector, _ body: () async throws -> T) async rethrows -> T {
        let original = FastqRiboDetectorSubcommand.toolRunner
        FastqRiboDetectorSubcommand.toolRunner = fake
        defer { FastqRiboDetectorSubcommand.toolRunner = original }
        return try await body()
    }

    // MARK: - Interleaved bundle: whole pairs in, whole pairs out

    func testInterleavedBundleRunsPairedAndDropsBothMatesOfAnRRNAFragment() async throws {
        for naming in InterleavedFASTQFixture.MateNaming.allCases {
            let ribosomalPairs: Set<Int> = [1, 4, 6]
            let bundle = try InterleavedFASTQFixture.writeBundle(
                named: "ribo-\(naming.rawValue)", in: root, pairCount: 8, naming: naming
            )
            let fake = FakeRiboDetector(ribosomal: Set(ribosomalPairs.map(InterleavedFASTQFixture.fragmentName)))
            let outputDirectory = root.appendingPathComponent("out-\(naming.rawValue)", isDirectory: true)

            // No --pairing flag: the CLI reads pairingMode from the bundle.
            try await withFakeTool(fake) {
                try await FastqRiboDetectorSubcommand.parse([
                    bundle.fastqURL.path, "--retain", "both", "--read-length", "60", "-o", outputDirectory.path,
                ]).run()
            }

            let arguments = try XCTUnwrap(fake.invocations.first, naming.rawValue)
            let inputIndex = try XCTUnwrap(arguments.firstIndex(of: "-i"))
            XCTAssertTrue(arguments[inputIndex + 1].hasSuffix(".input.R1.fastq"), "ribodetector must get R1: \(arguments)")
            XCTAssertTrue(arguments[inputIndex + 2].hasSuffix(".input.R2.fastq"), "and R2: \(arguments)")

            let kept = try await InterleavedFASTQFixture.readRecords(
                at: outputDirectory.appendingPathComponent("ribo-\(naming.rawValue).norrna.fastq")
            )
            InterleavedFASTQFixture.assertWholePairs(kept, "norrna \(naming.rawValue)")
            XCTAssertEqual(kept.count, (8 - ribosomalPairs.count) * 2, naming.rawValue)
            let keptKeys = InterleavedFASTQFixture.fragmentKeys(kept)
            for index in ribosomalPairs {
                XCTAssertFalse(keptKeys.contains(InterleavedFASTQFixture.fragmentName(index)), "pair \(index) must be dropped whole")
            }

            let removed = try await InterleavedFASTQFixture.readRecords(
                at: outputDirectory.appendingPathComponent("ribo-\(naming.rawValue).rrna.fastq")
            )
            InterleavedFASTQFixture.assertWholePairs(removed, "rrna \(naming.rawValue)")
            XCTAssertEqual(
                InterleavedFASTQFixture.fragmentKeys(removed),
                Set(ribosomalPairs.map(InterleavedFASTQFixture.fragmentName)),
                naming.rawValue
            )

            // The scratch mates are gone; only the planned outputs remain.
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
                .filter { $0.hasPrefix(".ribodetector-pairs") }
            XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
        }
    }

    func testRetainNonRRNAOnlyStillJoinsThePairs() async throws {
        let bundle = try InterleavedFASTQFixture.writeBundle(named: "keep", in: root, pairCount: 5, naming: .identical)
        let fake = FakeRiboDetector(ribosomal: [InterleavedFASTQFixture.fragmentName(2)])
        let outputDirectory = root.appendingPathComponent("out", isDirectory: true)

        try await withFakeTool(fake) {
            try await FastqRiboDetectorSubcommand.parse([
                bundle.fastqURL.path, "--pairing", "interleaved", "--read-length", "60", "-o", outputDirectory.path,
            ]).run()
        }

        let kept = try await InterleavedFASTQFixture.readRecords(at: outputDirectory.appendingPathComponent("keep.norrna.fastq"))
        InterleavedFASTQFixture.assertWholePairs(kept)
        XCTAssertEqual(kept.count, 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("keep.rrna.fastq").path))
    }

    // MARK: - Layouts that must not be split by position

    func testMixedFileRunsAsSingleReadsEvenWhenToldInterleaved() async throws {
        let bundle = try InterleavedFASTQFixture.writeMixedBundle(named: "mixed", in: root, pairCount: 3, mergedCount: 2, naming: .slashSuffix)
        let fake = FakeRiboDetector(ribosomal: [InterleavedFASTQFixture.mergedName(0)])
        let outputDirectory = root.appendingPathComponent("out", isDirectory: true)

        try await withFakeTool(fake) {
            try await FastqRiboDetectorSubcommand.parse([
                bundle.fastqURL.path, "--pairing", "interleaved", "--read-length", "60", "-o", outputDirectory.path,
            ]).run()
        }

        let arguments = try XCTUnwrap(fake.invocations.first)
        let inputIndex = try XCTUnwrap(arguments.firstIndex(of: "-i"))
        XCTAssertEqual(arguments[inputIndex + 1], bundle.fastqURL.path, "a mixed file is handed over whole")
        XCTAssertEqual(arguments[inputIndex + 2], "-e")
        let kept = try await InterleavedFASTQFixture.readRecords(at: outputDirectory.appendingPathComponent("mixed.norrna.fastq"))
        XCTAssertEqual(kept.count, 3 * 2 + 2 - 1)
    }

    func testExplicitR1R2InputsAreHandedOverAsIs() async throws {
        let r1 = root.appendingPathComponent("x_R1.fastq")
        let r2 = root.appendingPathComponent("x_R2.fastq")
        try "@a/1\nACGTACGTAC\n+\nIIIIIIIIII\n".write(to: r1, atomically: true, encoding: .utf8)
        try "@a/2\nACGTACGTAC\n+\nIIIIIIIIII\n".write(to: r2, atomically: true, encoding: .utf8)
        let fake = FakeRiboDetector(ribosomal: [])
        let outputDirectory = root.appendingPathComponent("out", isDirectory: true)

        try await withFakeTool(fake) {
            try await FastqRiboDetectorSubcommand.parse([r1.path, r2.path, "--read-length", "10", "-o", outputDirectory.path]).run()
        }

        let arguments = try XCTUnwrap(fake.invocations.first)
        let inputIndex = try XCTUnwrap(arguments.firstIndex(of: "-i"))
        XCTAssertEqual(Array(arguments[(inputIndex + 1)...(inputIndex + 2)]), [r1.path, r2.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("x_R1.norrna.fastq").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("x_R2.norrna.fastq").path))
    }

    func testPairedInvocationPlanMapsEveryClassToScratchMatesAndJoinsRetainedOnes() throws {
        let outputDirectory = root.appendingPathComponent("out", isDirectory: true)
        let scratch = outputDirectory.appendingPathComponent(".scratch", isDirectory: true)
        let plan = try FastqRiboDetectorSubcommand.plannedOutputs(
            inputURLs: [root.appendingPathComponent("s.fastq.gz")],
            outputDirectory: outputDirectory,
            retention: .rRNA
        )

        let paired = FastqRiboDetectorSubcommand.pairedInvocationPlan(for: plan, scratchDirectory: scratch)

        XCTAssertEqual(paired.toolPlan.nonRRNAOutputURLs.map(\.lastPathComponent), [".s.norrna.discarded.R1.fastq", ".s.norrna.discarded.R2.fastq"])
        XCTAssertEqual(paired.toolPlan.rRNAOutputURLs?.map(\.lastPathComponent), ["s.rrna.R1.fastq", "s.rrna.R2.fastq"])
        XCTAssertEqual(paired.joins.map(\.output), plan.retainedOutputURLs)
        XCTAssertEqual(paired.joins.map { $0.r1.lastPathComponent }, ["s.rrna.R1.fastq"])
        XCTAssertTrue(paired.toolPlan.removeNonRRNAOutputsAfterRun)
    }

    // MARK: - Installed tool

    /// The real `ribodetector_cpu` on a paired split must return whole pairs:
    /// this is the claim the registry declaration makes about the tool.
    func testInstalledRiboDetectorReturnsWholePairsFromAnInterleavedBundle() async throws {
        _ = try await ToolAvailability.require("ribodetector_cpu", environment: "ribodetector")
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "real", in: root, pairCount: 12, naming: .identical,
            sequences: { index in
                (InterleavedFASTQFixture.deterministicSequence(seed: UInt64(index * 2 + 1), length: 100),
                 InterleavedFASTQFixture.deterministicSequence(seed: UInt64(index * 2 + 2), length: 100))
            }
        )
        let outputDirectory = root.appendingPathComponent("real-out", isDirectory: true)

        try await FastqRiboDetectorSubcommand.parse([
            bundle.fastqURL.path, "--retain", "both", "--threads", "2", "-o", outputDirectory.path,
        ]).run()

        let kept = try await InterleavedFASTQFixture.readRecords(at: outputDirectory.appendingPathComponent("real.norrna.fastq"))
        let removed = try await InterleavedFASTQFixture.readRecords(at: outputDirectory.appendingPathComponent("real.rrna.fastq"))
        InterleavedFASTQFixture.assertWholePairs(kept, "norrna")
        InterleavedFASTQFixture.assertWholePairs(removed, "rrna")
        XCTAssertEqual(kept.count + removed.count, 24, "every read lands in exactly one class")
        XCTAssertTrue(InterleavedFASTQFixture.fragmentKeys(kept).isDisjoint(with: InterleavedFASTQFixture.fragmentKeys(removed)))
    }
}
