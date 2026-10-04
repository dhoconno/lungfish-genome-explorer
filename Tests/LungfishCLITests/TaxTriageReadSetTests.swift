// TaxTriageReadSetTests.swift - lungfish-cli taxtriage run hands TaxTriage the pairs and every read of a bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner decision 1 of 2026-10-03 (docs/contracts/READ-PAIRING.md): pairs that
// were not merged reach a tool as pairs whenever it can take them, and nothing
// is dropped. TaxTriage reads pairs only as the samplesheet's fastq_1 and
// fastq_2, one file each, so a mixed sample or several chunks run as one file of
// single reads. Read names say what each read is, as in ReadSetFixtures.
//
// `taxtriage run --input <bundle>` resolves each sample through
// `TaxTriageCommand.RunSubcommand.resolveSamples`, the planner the app's
// TaxTriage launch runs too. Before it, the command read a bundle through
// `resolveReadsFile`, which took R1 only (a paired derivative), the merged file
// only (a merge derivative), the first file (a repair derivative), `preview.fastq`
// (a virtual bundle), and refused a chunked root.

import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

final class TaxTriageReadSetTests: XCTestCase {

    private var root: URL!
    private var fixtures: ReadSetFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-read-sets")
        fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Samples TaxTriage already runs, pinned

    func testASingleEndRootIsOneFile() async throws {
        let sample = try await resolve(fixtures.singleRoot)
        XCTAssertEqual(try reads(of: sample), [["s1", "s2", "s3"]])
        XCTAssertEqual(sample.readLayout, .singleEnd)
        XCTAssertNil(sample.readSetPlan?.singleReadReason)
    }

    /// The pipeline splits a strictly interleaved file into R1 and R2 as it
    /// does today, so the sample reaches it as one interleaved file.
    func testAnInterleavedRootIsOneInterleavedFile() async throws {
        let sample = try await resolve(fixtures.interleavedRoot)
        XCTAssertEqual(try reads(of: sample), [["i1/1", "i1/2", "i2/1", "i2/2"]])
        XCTAssertEqual(sample.readLayout, .strictlyInterleaved)
        XCTAssertTrue(TaxTriagePipeline.shouldSplitInterleaved(sample), "the pipeline splits it into R1 and R2")
    }

    /// After the pipeline's own split, the samplesheet row of an interleaved
    /// root is a pair, as it has been.
    func testAnInterleavedRootBecomesAPairedSamplesheetRowAfterThePipelineSplit() async throws {
        let sample = try await resolve(fixtures.interleavedRoot)
        let prepared = try await TaxTriagePipeline.splitStrictlyInterleavedSamples(
            in: TaxTriageConfig(samples: [sample], outputDirectory: root.appendingPathComponent("out", isDirectory: true)),
            splitRoot: root.appendingPathComponent("split", isDirectory: true)
        )
        let entry = try XCTUnwrap(TaxTriagePipeline.samplesheetEntries(for: prepared.config).first)
        XCTAssertEqual(try ReadSetFixtures.readNames(in: URL(fileURLWithPath: entry.fastq1Path)), ["i1/1", "i2/1"])
        XCTAssertEqual(
            try entry.fastq2Path.map { try ReadSetFixtures.readNames(in: URL(fileURLWithPath: $0)) },
            ["i1/2", "i2/2"]
        )
    }

    /// L3. The one file was already a single-end row. The run now says why.
    func testAMixedRootIsOneFileOfEveryReadAndSaysWhy() async throws {
        let sample = try await resolve(fixtures.mixedRoot)
        XCTAssertEqual(try reads(of: sample), [["m1", "m2", "m3", "p1/1", "p1/2", "p2/1", "p2/2"]])
        XCTAssertEqual(sample.readLayout, .mixedMergedAndPairs)
        try assertReasonRecorded(sample)
    }

    // MARK: - Every read reaches TaxTriage

    /// L5b. Before: R1 only, `p1/1` and `p2/1`, so the mates were never seen.
    /// After: fastq_1 holds R1 and fastq_2 holds R2.
    func testAPairedDerivativeIsHandedBothMates() async throws {
        let sample = try await resolve(fixtures.pairedDerivative)
        XCTAssertEqual(try reads(of: sample), [["p1/1", "p2/1"], ["p1/2", "p2/2"]])
        XCTAssertEqual(sample.readLayout, .pairedFiles)
        XCTAssertNil(sample.readSetPlan?.singleReadReason)
    }

    /// L5c. Before: the first file by name, `merged.fastq`, three of the five
    /// reads. After: one file of all five reads, and the reason.
    func testAMergeDerivativeIsHandedEveryRead() async throws {
        let sample = try await resolve(fixtures.mergeDerivative)
        let files = try reads(of: sample)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.sorted(), ["u1/1", "u1/2", "x1", "x2", "x3"])
        try assertReasonRecorded(sample)
        try assertJoinRecorded(sample, members: ["merged.fastq", "unmerged_R1.fastq", "unmerged_R2.fastq"])
    }

    /// L5d. Before: the first file by name, `repaired_R1.fastq`, two of the
    /// five reads. After: one file of all five reads, and the reason.
    func testARepairDerivativeIsHandedEveryRead() async throws {
        let sample = try await resolve(fixtures.repairDerivative)
        let files = try reads(of: sample)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.sorted(), ["o1", "r1/1", "r1/2", "r2/1", "r2/2"])
        try assertReasonRecorded(sample)
        try assertJoinRecorded(sample, members: ["repaired_R1.fastq", "repaired_R2.fastq", "singletons.fastq"])
    }

    /// L4. Before: the command refused a bundle of two chunks. After: one
    /// file of the three reads of both chunks, joined in chunk order. Chunks of
    /// one run are single reads, so no reason is recorded.
    func testAChunkedRootIsHandedEveryChunkAsOneFile() async throws {
        let sample = try await resolve(fixtures.chunkedRoot)
        XCTAssertEqual(try reads(of: sample), [["c1", "c2", "c3"]])
        XCTAssertNil(sample.fastq2)
        XCTAssertEqual(sample.readLayout, .singleEnd)
        XCTAssertNil(sample.readSetPlan?.singleReadReason)
        try assertJoinRecorded(sample, members: ["run_0.fastq", "run_1.fastq"])
    }

    /// Two chunks of a Nanopore import named like mates are single reads, so
    /// they are joined and never written as fastq_1 and fastq_2.
    func testNanoporeChunksNamedLikeMatesAreJoinedNotPaired() async throws {
        let sample = try await resolve(fixtures.nanoporeChunkedRoot)
        XCTAssertNil(sample.fastq2, "chunks of one run are not mates")
        XCTAssertEqual(try reads(of: sample).first?.sorted(), ["o-a", "o-b", "o-c"])
    }

    /// L6. Before: `preview.fastq`, which holds a preview of the sample and
    /// not the sample. After: the materialized reads.
    func testAVirtualSubsetOfASingleEndRootIsItsMaterializedReads() async throws {
        let sample = try await resolve(fixtures.subsetOfSingle)
        XCTAssertEqual(try reads(of: sample), [["s1", "s3"]])
        XCTAssertNil(sample.readSetPlan?.singleReadReason)
    }

    /// L6 of a merge derivative. The materialized file mixes a pair with a
    /// merged read, so it runs single-end and the run says why.
    func testAVirtualSubsetOfAMergeDerivativeIsOneFileAndSaysWhy() async throws {
        let sample = try await resolve(fixtures.subsetOfMerge)
        XCTAssertEqual(try reads(of: sample), [["u1/1", "u1/2", "x1"]])
        try assertReasonRecorded(sample)
    }

    /// L6 of an interleaved root. The materialized pair stays one interleaved
    /// file for the pipeline to split.
    func testAVirtualSubsetOfAnInterleavedRootIsOneInterleavedFile() async throws {
        let sample = try await resolve(fixtures.subsetOfInterleaved)
        XCTAssertEqual(try reads(of: sample), [["i1/1", "i1/2"]])
        XCTAssertEqual(sample.readLayout, .strictlyInterleaved)
    }

    // MARK: - Files the user names are read as they are

    func testALooseFileIsReadAsItIs() async throws {
        let file = root.appendingPathComponent("loose.fastq")
        try ReadSetFixtures.fastq(["l1", "l2"]).write(to: file, atomically: true, encoding: .utf8)
        let sample = try await resolve(file)
        XCTAssertEqual(sample.fastq1, file)
        XCTAssertNil(sample.fastq2)
        XCTAssertNil(sample.readLayout)
        XCTAssertNil(sample.readSetPlan)
    }

    func testTwoNamedMateFilesAreReadAsTheyAre() async throws {
        let r1 = root.appendingPathComponent("s_R1.fastq")
        let r2 = root.appendingPathComponent("s_R2.fastq")
        try ReadSetFixtures.fastq(["a/1"]).write(to: r1, atomically: true, encoding: .utf8)
        try ReadSetFixtures.fastq(["a/2"]).write(to: r2, atomically: true, encoding: .utf8)
        let resolved = try await TaxTriageCommand.RunSubcommand.resolveSamples(
            [TaxTriageSample(sampleId: "s", fastq1: r1, fastq2: r2)],
            materializationDirectory: scratch(),
            materializer: fixtures.materializer
        )
        XCTAssertEqual(resolved.first?.fastq1, r1)
        XCTAssertEqual(resolved.first?.fastq2, r2)
    }

    // MARK: - Files named inside a bundle (coordinator's ruling of 2026-10-04)

    /// Case 1. `--input <one file inside a bundle>` reads that file as named,
    /// as it always did. The mate beside it and the chunks around it are not
    /// read. The planner used to take the whole enclosing bundle.
    func testOneFileInsideABundleIsReadAsNamed() async throws {
        let r1 = fixtures.pairedDerivative.appendingPathComponent("sample_R1.fastq")
        let mate = try await resolve(r1)
        XCTAssertEqual(try reads(of: mate), [["p1/1", "p2/1"]])
        XCTAssertNil(mate.readSetPlan)

        let chunk = try XCTUnwrap(FASTQBundle.resolveAllFASTQURLs(for: fixtures.chunkedRoot)?.first)
        let named = try await resolve(chunk)
        XCTAssertEqual(try reads(of: named), [["c1", "c2"]], "chunk 0 of the run, not both chunks")
        XCTAssertNil(named.readSetPlan)
    }

    /// Case 2. `--input <chunk> --input2 <chunk>` naming every member file of
    /// one bundle collapses to the bundle. Two chunks of one run are single
    /// reads, so the sample is one joined file, and the two chunks are not
    /// written as `fastq_1` and `fastq_2`.
    func testEveryMemberFileGivenWithInputAndInput2CollapsesToTheBundle() async throws {
        let chunks = try XCTUnwrap(FASTQBundle.resolveAllFASTQURLs(for: fixtures.chunkedRoot))
        let sample = try await resolve(chunks[0], input2: chunks[1])
        XCTAssertNil(sample.fastq2, "chunks of one run are not mates")
        XCTAssertEqual(try reads(of: sample), [["c1", "c2", "c3"]])
        try assertJoinRecorded(sample, members: ["run_0.fastq", "run_1.fastq"])

        let r1 = fixtures.pairedDerivative.appendingPathComponent("sample_R1.fastq")
        let r2 = fixtures.pairedDerivative.appendingPathComponent("sample_R2.fastq")
        let pair = try await resolve(r1, input2: r2)
        XCTAssertEqual(try reads(of: pair), [["p1/1", "p2/1"], ["p1/2", "p2/2"]])
        XCTAssertEqual(pair.readSetPlan?.inputURL, fixtures.pairedDerivative.standardizedFileURL, "planned as the bundle")
    }

    /// A part of a bundle's files is read as named.
    func testPartOfABundlesFilesGivenWithInputAndInput2AreReadAsNamed() async throws {
        let r1 = fixtures.mergeDerivative.appendingPathComponent("unmerged_R1.fastq")
        let r2 = fixtures.mergeDerivative.appendingPathComponent("unmerged_R2.fastq")
        let pair = try await resolve(r1, input2: r2)
        XCTAssertEqual(try reads(of: pair), [["u1/1"], ["u1/2"]])
        XCTAssertNil(pair.readSetPlan)
    }

    /// Case 3. `--input <bundle>` is the whole bundle.
    func testABundlePathIsTheWholeBundle() async throws {
        let sample = try await resolve(fixtures.mergeDerivative)
        XCTAssertEqual(try reads(of: sample).first?.count, 5)
        XCTAssertNotNil(sample.readSetPlan)
    }

    // MARK: - Nothing is written for a sample that needs nothing

    func testASampleOfSingleReadsWritesNothingToTheScratchFolder() async throws {
        let directory = scratch()
        _ = try await TaxTriageCommand.RunSubcommand.resolveSamples(
            [TaxTriageSample(sampleId: "single", fastq1: fixtures.singleRoot)],
            materializationDirectory: directory,
            materializer: fixtures.materializer
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "no join and no materialization happened")
    }

    // MARK: - Helpers

    private func scratch() -> URL {
        root.appendingPathComponent("inputs-\(UUID().uuidString)", isDirectory: true)
    }

    /// The sample `lungfish-cli taxtriage run --input <input> [--input2
    /// <input2>]` builds, resolved to the files TaxTriage reads.
    private func resolve(_ input: URL, input2: URL? = nil) async throws -> TaxTriageSample {
        let resolved = try await TaxTriageCommand.RunSubcommand.resolveSamples(
            [TaxTriageSample(sampleId: "sample", fastq1: input, fastq2: input2)],
            materializationDirectory: scratch(),
            materializer: fixtures.materializer
        )
        return try XCTUnwrap(resolved.first)
    }

    /// The record names of each file TaxTriage reads for the sample, fastq_1
    /// then fastq_2.
    private func reads(of sample: TaxTriageSample) throws -> [[String]] {
        try ([sample.fastq1] + (sample.fastq2.map { [$0] } ?? [])).map(ReadSetFixtures.readNames(in:))
    }

    /// A mixed sample runs single-end and says why, in its plan.
    private func assertReasonRecorded(_ sample: TaxTriageSample, file: StaticString = #filePath, line: UInt = #line) throws {
        let plan = try XCTUnwrap(sample.readSetPlan, "the sample records its read-set plan", file: file, line: line)
        let reason = try XCTUnwrap(plan.singleReadReason, "the plan says why every read runs single-end", file: file, line: line)
        XCTAssertTrue(reason.contains("cannot pair part of a sample"), reason, file: file, line: line)
        XCTAssertEqual(plan.capability, .pairsOnlyWhenAllPaired, file: file, line: line)
        XCTAssertNil(sample.fastq2, "a mixed sample is not a pair", file: file, line: line)
    }

    /// The `cat` that joined the sample's files is on disk beside the joined
    /// file, naming each member.
    private func assertJoinRecorded(
        _ sample: TaxTriageSample,
        members: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let join = try XCTUnwrap(SequenceInputConcatenation.load(for: sample.fastq1), "the join writes its sidecar", file: file, line: line)
        XCTAssertEqual(join.memberURLs.map(\.lastPathComponent), members, file: file, line: line)
        XCTAssertEqual(join.outputURL.standardizedFileURL, sample.fastq1.standardizedFileURL, file: file, line: line)
        XCTAssertTrue(join.command.last?.hasPrefix("cat ") == true, "\(join.command)", file: file, line: line)
    }
}
