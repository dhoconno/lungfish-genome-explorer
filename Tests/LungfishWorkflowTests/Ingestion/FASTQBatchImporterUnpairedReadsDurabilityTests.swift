// FASTQBatchImporterUnpairedReadsDurabilityTests.swift - The pairs-then-reads join publishes whole or not at all
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 2.10 lane S31, the follow-up grant. The importer joins a sample's
/// pairs and its reads without a mate into one file in the import workspace
/// (`FASTQBatchImporter.writePairsThenUnpairedReads`). The base opened the
/// final name first and let the interleaver fill it, so a join that a later
/// check refused left the reads written so far under that name. It now
/// streams into a hidden stage file and names the result only when it is
/// whole and synced.
///
/// The class name holds `Durability`, so `exfat-tests.sh --simulate` runs it
/// with every rename taking its ExFAT fallback. The byte pins are
/// `ReadWriterHandleSitePinTests`.
final class FASTQBatchImporterUnpairedReadsDurabilityTests: XCTestCase {
    private typealias Fixtures = ReadWriterFixtures
    private var root: URL!
    private var workspace: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "unpaired-join-durability")
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func sample(pairs: [String], singles: [String], r2Names: [String]? = nil) throws -> SamplePair {
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        let r1 = try Fixtures.write(Fixtures.mates(pairs.map { "\($0)/1" }, base: "A"), named: "S_R1.fastq", in: inputs)
        let r2 = try Fixtures.write(
            Fixtures.mates(r2Names ?? pairs.map { "\($0)/2" }, base: "C"),
            named: "S_R2.fastq",
            in: inputs
        )
        let unpaired = try Fixtures.write(Fixtures.mates(singles, base: "G"), named: "S.fastq", in: inputs)
        return SamplePair(sampleName: "S", r1: r1, r2: r2, unpaired: unpaired)
    }

    private func refusal(of pair: SamplePair) async -> Error? {
        await Fixtures.capturedError {
            _ = try await FASTQBatchImporter.writePairsThenUnpairedReads(of: pair, in: workspace, log: nil)
        }
    }

    // MARK: - A join that a later check refuses

    /// The first check compares the first 1,000 reads of the third file. The
    /// join compares the rest as it copies them, after the pairs went out.
    func testReadsThatLookLikeACopyOfThePairPartWayLeaveNoPartFileInTheWorkspace() async throws {
        let singles = (1...1_002).map { "u\($0)" } + ["x/1", "x/2"]
        let pair = try sample(pairs: ["p1", "p2"], singles: singles)

        let error = await refusal(of: pair)

        guard case .notJoinable? = error as? FASTQBatchImporter.UnpairedReadsImportError else {
            return XCTFail("expected a refusal that the file is not joinable, got \(String(describing: error))")
        }
        XCTAssertEqual(try Fixtures.entries(of: workspace), [], "a refused join names no file and leaves no stage file")
    }

    /// The first check names the first pair only. The interleaver checks every
    /// pair, and refuses the one at record 1,200 after 1,199 pairs went out.
    func testMatesThatAreOutOfStepPartWayLeaveNoPartFileInTheWorkspace() async throws {
        let pairs = (1...1_500).map { "p\($0)" }
        var r2Names = pairs.map { "\($0)/2" }
        r2Names[1_199] = "other/2"
        let pair = try sample(pairs: pairs, singles: ["u1"], r2Names: r2Names)

        let error = await refusal(of: pair)

        guard case .mateNameMismatch(let recordNumber, _, _, _, _)? = error as? FASTQPairInterleaver.InterleaveError else {
            return XCTFail("expected a mate name mismatch, got \(String(describing: error))")
        }
        XCTAssertEqual(recordNumber, 1_200)
        XCTAssertEqual(try Fixtures.entries(of: workspace), [], "a refused join names no file and leaves no stage file")
    }

    // MARK: - The synchronous join

    // The route runs the join in a detached task, which does not inherit the
    // task-local seam of `DurableReplace.Operations`, so these call the join.

    func testAFullDiskIsAThrownErrorAndTheNameKeepsItsOldFile() throws {
        let pair = try sample(pairs: ["p1", "p2"], singles: ["u1", "u2"])
        let output = try Fixtures.write(Data("old\n".utf8), named: "S_pairs_then_unpaired.fastq", in: workspace)
        let tally = Fixtures.Tally()
        let operations = Fixtures.fullDisk(
            afterWrites: 0,
            matching: ".S_pairs_then_unpaired.fastq.lungfish-stage-",
            tally: tally
        )

        XCTAssertThrowsError(
            try DurableReplace.$overrideOperations.withValue(operations) {
                try FASTQBatchImporter.joinPairsThenUnpairedReads(
                    r1: pair.r1,
                    r2: XCTUnwrap(pair.r2),
                    unpaired: XCTUnwrap(pair.unpaired),
                    into: output
                )
            }
        ) { Fixtures.assertFullDisk($0) }

        XCTAssertEqual(tally["stageWrites"], 1, "the write after the failure never ran")
        XCTAssertEqual(try Data(contentsOf: output), Data("old\n".utf8))
        XCTAssertEqual(try Fixtures.entries(of: workspace), ["S_pairs_then_unpaired.fastq"], "no stage file is left")
    }

    func testTheJoinIsSyncedBeforeItIsNamedAndReturnsItsCounts() throws {
        let pair = try sample(pairs: ["p1", "p2"], singles: ["u1", "u2", "u3"])
        let output = workspace.appendingPathComponent("S_pairs_then_unpaired.fastq")
        let tally = Fixtures.Tally()
        let operations = DurableReplace.Operations(
            syncFile: { tally.add("syncFile"); return Darwin.fsync($0) },
            checkpoint: { tally.add($0.rawValue) }
        )

        let counts = try DurableReplace.$overrideOperations.withValue(operations) {
            try FASTQBatchImporter.joinPairsThenUnpairedReads(
                r1: pair.r1,
                r2: XCTUnwrap(pair.r2),
                unpaired: XCTUnwrap(pair.unpaired),
                into: output
            )
        }

        XCTAssertEqual(counts.pairs, 2)
        XCTAssertEqual(counts.unpairedReads, 3)
        XCTAssertEqual(tally["syncFile"], 1, "one fsync of the file")
        XCTAssertEqual(tally["published"], 1)
        XCTAssertEqual(try Fixtures.entries(of: workspace), ["S_pairs_then_unpaired.fastq"])
        XCTAssertEqual(
            try Data(contentsOf: output),
            Fixtures.mates(["p1/1"], base: "A") + Fixtures.mates(["p1/2"], base: "C")
                + Fixtures.mates(["p2/1"], base: "A") + Fixtures.mates(["p2/2"], base: "C")
                + Fixtures.mates(["u1", "u2", "u3"], base: "G")
        )
    }
}
