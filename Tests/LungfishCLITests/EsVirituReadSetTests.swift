// EsVirituReadSetTests.swift - lungfish-cli esviritu detect hands EsViritu the pairs and every read of a bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner decision 1 of 2026-10-03 (docs/contracts/READ-PAIRING.md): pairs that
// were not merged reach a tool as pairs whenever it can take them, and nothing
// is dropped. EsViritu 1.3.3 takes `-p paired` with exactly two files and
// `-p unpaired` or `-p interleaved` with exactly one. Given several files with
// `-p unpaired` it logs "must provide exactly 1 read file", writes nothing and
// exits 0, so LGE reports `detectionOutputNotProduced`.
//
// A stand-in EsViritu keeps a copy of every file handed to `-r` and notes the
// `-p` format. Every bundle shape is run through `--read-format auto`, the
// value the app records when the read plan needs the planner. Read names say
// what each read is, as in ReadSetFixtures.

import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

final class EsVirituReadSetTests: XCTestCase {

    private var root: URL!
    private var fixtures: ReadSetFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "esviritu-read-sets")
        fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Samples EsViritu already runs, pinned byte for byte

    func testASingleEndRootRunsUnpairedWithItsOneFile() async throws {
        let run = try await detect(fixtures.singleRoot)
        XCTAssertEqual(run.formatSeen, "unpaired")
        XCTAssertEqual(run.filesSeen, [["s1", "s2", "s3"]])
        XCTAssertNil(run.plan, "a sample of single reads only records no plan")
    }

    func testAnInterleavedRootRunsInterleavedWithItsOneFile() async throws {
        let run = try await detect(fixtures.interleavedRoot)
        XCTAssertEqual(run.formatSeen, "interleaved")
        XCTAssertEqual(run.filesSeen, [["i1/1", "i1/2", "i2/1", "i2/2"]])
        XCTAssertNil(run.plan, "a sample of pairs only records no plan")
    }

    func testAVirtualSubsetOfASingleEndRootRunsUnpairedOnItsMaterializedFile() async throws {
        let run = try await detect(fixtures.subsetOfSingle)
        XCTAssertEqual(run.formatSeen, "unpaired")
        XCTAssertEqual(run.filesSeen, [["s1", "s3"]])
        XCTAssertNil(run.plan)
    }

    // MARK: - A deinterleaved bundle runs as pairs

    /// L5b. Before: `-r sample_R1 sample_R2 -p unpaired`, which EsViritu
    /// refuses. After: `-p paired` with both files, two reads each.
    func testAPairedDerivativeRunsAsAPair() async throws {
        let run = try await detect(fixtures.pairedDerivative)
        XCTAssertEqual(run.formatSeen, "paired")
        XCTAssertEqual(run.filesSeen, [["p1/1", "p2/1"], ["p1/2", "p2/2"]])
        XCTAssertNil(run.plan, "a sample of pairs only records no plan")
    }

    // MARK: - Mixed samples run single-end with every read in one file

    /// L5c. Before: `-r merged unmerged_R1 unmerged_R2 -p unpaired`, which
    /// EsViritu refuses. After: one file with all five reads, run unpaired,
    /// and the reason recorded.
    func testAMergeDerivativeRunsEveryReadSingleEndInOneFile() async throws {
        let run = try await detect(fixtures.mergeDerivative)
        XCTAssertEqual(run.formatSeen, "unpaired")
        XCTAssertEqual(run.filesSeen.count, 1, "EsViritu takes exactly one file with -p unpaired")
        XCTAssertEqual(run.filesSeen.first?.sorted(), ["u1/1", "u1/2", "x1", "x2", "x3"])
        try assertReasonRecorded(run)
        try assertJoinRecorded(run, members: ["merged.fastq", "unmerged_R1.fastq", "unmerged_R2.fastq"], in: fixtures.mergeDerivative)
    }

    /// L5d. Before: three files with `-p unpaired`, refused. After: one file
    /// with the two pairs and the orphan, five reads.
    func testARepairDerivativeRunsEveryReadSingleEndInOneFile() async throws {
        let run = try await detect(fixtures.repairDerivative)
        XCTAssertEqual(run.formatSeen, "unpaired")
        XCTAssertEqual(run.filesSeen.count, 1)
        XCTAssertEqual(run.filesSeen.first?.sorted(), ["o1", "r1/1", "r1/2", "r2/1", "r2/2"])
        try assertReasonRecorded(run)
        try assertJoinRecorded(run, members: ["repaired_R1.fastq", "repaired_R2.fastq", "singletons.fastq"], in: fixtures.repairDerivative)
    }

    /// L3. EsViritu already ran the one file unpaired. The run now records why.
    func testAMixedRootRunsItsOneFileUnpairedAndRecordsWhy() async throws {
        let run = try await detect(fixtures.mixedRoot)
        XCTAssertEqual(run.formatSeen, "unpaired")
        XCTAssertEqual(run.filesSeen, [["m1", "m2", "m3", "p1/1", "p1/2", "p2/1", "p2/2"]])
        try assertReasonRecorded(run)
        XCTAssertEqual(run.parameters?["inputMaterializationCommands"], .array([]), "nothing was joined or materialized")
    }

    /// L6 of a merge derivative. The materialized file mixes pairs and merged
    /// reads, so it runs unpaired and the run records why.
    func testAVirtualSubsetOfAMergeDerivativeRunsUnpairedAndRecordsWhy() async throws {
        let run = try await detect(fixtures.subsetOfMerge)
        XCTAssertEqual(run.formatSeen, "unpaired")
        XCTAssertEqual(run.filesSeen, [["u1/1", "u1/2", "x1"]])
        try assertReasonRecorded(run)
    }

    /// Phase 1.5 lane F6, re-review SHOULD-FIX 1. The materialized file of a subset of
    /// a merge derivative holds only the unmerged pair. The layout scan reads
    /// the merge in its lineage as proof of single reads, and EsViritu ran
    /// `-p unpaired` on both mates. The plan reads the whole file and finds
    /// no read without a mate, so the run is `-p interleaved` and its recorded
    /// layout is not mixed.
    func testAVirtualSubsetOfAMergeDerivativeThatHoldsOnlyPairsRunsInterleaved() async throws {
        let materializer = ReadSetFixtures.StubMaterializer(readsByBundlePath: [
            fixtures.subsetOfMerge.standardizedFileURL.path: ReadSetFixtures.fastq(["u1/1", "u1/2"]),
        ])
        let run = try await detect(fixtures.subsetOfMerge, materializer: materializer)
        XCTAssertEqual(run.formatSeen, "interleaved")
        XCTAssertEqual(run.filesSeen, [["u1/1", "u1/2"]])
        XCTAssertNil(run.plan, "a sample of pairs only records no plan")
        XCTAssertEqual(run.parameters?["readFormat"], .string("interleaved"))
        XCTAssertNil(run.parameters?["requestedReadFormat"], "the run was not changed after it was asked for")
        XCTAssertNotEqual(run.parameters?["inputReadLayout"], .string("mixed_interleaved"))
    }

    // MARK: - Chunks of single reads are joined

    /// L4. Before: `-r run_0 run_1 -p unpaired`, refused. After: one file
    /// with the three reads of both chunks. A chunked root holds single
    /// reads, so no reason is recorded.
    func testAChunkedRootIsJoinedIntoOneFile() async throws {
        let run = try await detect(fixtures.chunkedRoot)
        XCTAssertEqual(run.formatSeen, "unpaired")
        XCTAssertEqual(run.filesSeen, [["c1", "c2", "c3"]])
        XCTAssertNil(run.plan, "single reads only records no plan")
        try assertJoinRecorded(run, members: ["run_0.fastq", "run_1.fastq"], in: fixtures.chunkedRoot)
    }

    /// Two chunks of a Nanopore import that are named like mates are single
    /// reads, so they are joined, never run as `-p paired` (Phase 1.5 D9).
    func testNanoporeChunksNamedLikeMatesAreJoinedNotPaired() async throws {
        let run = try await detect(fixtures.nanoporeChunkedRoot)
        XCTAssertEqual(run.formatSeen, "unpaired")
        XCTAssertEqual(run.filesSeen.count, 1)
        XCTAssertEqual(run.filesSeen.first?.sorted(), ["o-a", "o-b", "o-c"])
    }

    // MARK: - An explicit read format keeps today's run

    func testAnExplicitUnpairedFormatKeepsHandingEveryFileOverAsItDid() async throws {
        let run = try await detect(fixtures.chunkedRoot, readFormat: "unpaired")
        XCTAssertEqual(run.formatSeen, "unpaired")
        XCTAssertEqual(run.filesSeen, [["c1", "c2"], ["c3"]])
    }

    // MARK: - Helpers

    private struct DetectRun {
        let outputDirectory: URL
        /// The record names of each file EsViritu was handed, in argument order.
        let filesSeen: [[String]]
        let formatSeen: String
        let parameters: [String: ParameterValue]?

        /// The recorded read-set plan, or nil when the run recorded none.
        var plan: [String: ParameterValue]? {
            if case .dictionary(let plan)? = parameters?["readSetPlan"] { return plan }
            return nil
        }
    }

    /// Runs `lungfish-cli esviritu detect --input <input> --read-format
    /// <readFormat>` through the command's own resolution with a stand-in
    /// EsViritu. A virtual bundle is written by the fixtures' stub.
    private func detect(
        _ input: URL,
        readFormat: String = "auto",
        materializer: (any CLISequenceInputMaterializing & Sendable)? = nil
    ) async throws -> DetectRun {
        let runRoot = root.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        let esviritu = try StandInEsViritu(root: runRoot)
        let outputDirectory = runRoot.appendingPathComponent("esviritu/sample", isDirectory: true)
        let parsed = try LungfishCLI.parseAsRoot([
            "esviritu", "detect",
            "--input", input.path,
            "--sample", "sample",
            "--read-format", readFormat,
            "--db", esviritu.databaseURL.path,
            "--output", outputDirectory.path,
            "--threads", "2",
            "--quiet",
        ])
        let command = try XCTUnwrap(parsed as? EsVirituCommand.DetectSubcommand)
        try await command.execute(
            pipeline: EsVirituPipeline(condaManager: esviritu.condaManager),
            materializer: materializer ?? fixtures.materializer
        )
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: outputDirectory))
        return DetectRun(
            outputDirectory: outputDirectory,
            filesSeen: try esviritu.inputsSeen().map(ReadSetFixtures.readNames(in:)),
            formatSeen: esviritu.formatSeen,
            parameters: envelope.options.explicit
        )
    }

    /// A mixed sample runs single-end and says why, in the run parameters.
    private func assertReasonRecorded(_ run: DetectRun, file: StaticString = #filePath, line: UInt = #line) throws {
        let plan = try XCTUnwrap(run.plan, "the run records its read-set plan", file: file, line: line)
        guard case .string(let reason)? = plan["singleReadReason"] else {
            return XCTFail("the plan records why every read ran single-end: \(plan)", file: file, line: line)
        }
        XCTAssertTrue(reason.contains("cannot pair part of a sample"), reason, file: file, line: line)
        XCTAssertEqual(plan["capability"], .string("pairs_only_when_all_paired"), file: file, line: line)
    }

    /// The joined file's `cat` command and its member files are recorded.
    private func assertJoinRecorded(
        _ run: DetectRun,
        members: [String],
        in bundle: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard case .array(let commands)? = run.parameters?["inputMaterializationCommands"] else {
            return XCTFail("the run records how its inputs were made", file: file, line: line)
        }
        XCTAssertEqual(commands.count, 1, file: file, line: line)
        guard case .string(let command)? = commands.first else {
            return XCTFail("the join is recorded as a command", file: file, line: line)
        }
        for member in members {
            XCTAssertTrue(command.contains(member), "\(member) is named in: \(command)", file: file, line: line)
        }
        XCTAssertTrue(command.contains("cat"), command, file: file, line: line)
        XCTAssertEqual(run.parameters?["originalInputs"], .array([.file(bundle.standardizedFileURL)]), file: file, line: line)
    }
}
