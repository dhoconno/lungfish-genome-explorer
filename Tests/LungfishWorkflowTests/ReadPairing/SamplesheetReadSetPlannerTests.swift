// SamplesheetReadSetPlannerTests.swift - How EsViritu and TaxTriage take the reads of one sample
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/contracts/READ-PAIRING.md. Both tools declare "pairs only when every
// fragment is paired". A sample of pairs only is one mate pair, a sample of
// single reads only is one file, and a sample that mixes pairs and single reads
// is one file of every read with the plan's stated reason. Several files of
// single reads are joined with the `cat` step and sidecar of
// `SequenceInputConcatenation`, so the tool never sees a file count it cannot
// take and no read is left out. Read names say what each read is, as in
// ReadSetFixtures.

import XCTest
@testable import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class SamplesheetReadSetPlannerTests: XCTestCase {

    private var root: URL!
    private var fixtures: ReadSetFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "samplesheet-read-set-planner")
        fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func scratch() -> URL {
        root.appendingPathComponent("inputs-\(UUID().uuidString)", isDirectory: true)
    }

    private func plan(
        _ input: URL,
        consumerID: String = EsVirituConfig.readPairingConsumerID,
        materializationDirectory: URL? = nil
    ) async throws -> SamplesheetReadSet {
        try await SamplesheetReadSetPlanner.plan(
            input: input,
            consumerID: consumerID,
            materializationDirectory: materializationDirectory ?? scratch(),
            materializer: fixtures.materializer
        )
    }

    private func names(_ readSet: SamplesheetReadSet) throws -> [[String]] {
        try readSet.executionURLs.map(ReadSetFixtures.readNames(in:))
    }

    // MARK: - A sample of one kind is handed over as it is found

    func testASampleOfSingleReadsIsOneFileAndWritesNothing() async throws {
        let directory = scratch()
        let readSet = try await plan(fixtures.singleRoot, materializationDirectory: directory)
        guard case .singleEnd(let url) = readSet.reads else { return XCTFail("\(readSet.reads)") }
        XCTAssertEqual(url.lastPathComponent, "single.fastq")
        XCTAssertNil(readSet.concatenation)
        XCTAssertFalse(readSet.changesTheRun, "a plain single-end file is what the tool runs without the planner")
        XCTAssertNil(readSet.writeStartedAt)
        XCTAssertNil(readSet.plan.singleReadReason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testAStrictlyInterleavedSampleIsOneInterleavedFile() async throws {
        let readSet = try await plan(fixtures.interleavedRoot)
        guard case .interleaved(let url) = readSet.reads else { return XCTFail("\(readSet.reads)") }
        XCTAssertEqual(url.lastPathComponent, "reads.fastq")
        XCTAssertFalse(readSet.changesTheRun, "one interleaved file is what the tool runs without the planner")
    }

    /// L5b. EsViritu takes `-p paired` with two files, and TaxTriage takes
    /// fastq_1 and fastq_2.
    func testAPairedDerivativeIsOneMatePair() async throws {
        let readSet = try await plan(fixtures.pairedDerivative)
        guard case .matePair(let r1, let r2) = readSet.reads else { return XCTFail("\(readSet.reads)") }
        XCTAssertEqual([r1.lastPathComponent, r2.lastPathComponent], ["sample_R1.fastq", "sample_R2.fastq"])
        XCTAssertTrue(readSet.changesTheRun)
        XCTAssertEqual(try names(readSet), [["p1/1", "p2/1"], ["p1/2", "p2/2"]])
        XCTAssertNil(readSet.concatenation)
        XCTAssertNil(readSet.plan.singleReadReason)
        XCTAssertFalse(readSet.resolvedInputs.inputs.first?.wasMaterialized ?? true)
        XCTAssertEqual(readSet.resolvedInputs.inputs.first?.isMatePair, true)
    }

    /// Two chunks named as R1 and R2 are one pair only when the bundle
    /// records a short-read platform, as the contract says for L4.
    func testChunksNamedAsMatesOfAnIlluminaRunAreOnePair() async throws {
        let readSet = try await plan(fixtures.namedPairChunkedRoot)
        guard case .matePair = readSet.reads else { return XCTFail("\(readSet.reads)") }
        XCTAssertEqual(try names(readSet), [["q1/1"], ["q1/2"]])
    }

    // MARK: - A mixed sample is one file of every read

    /// L3. One file of merged reads then pairs runs as it is, and the plan says why.
    func testAMixedFileIsOneFileOfEveryReadWithItsReason() async throws {
        let readSet = try await plan(fixtures.mixedRoot)
        guard case .singleEnd = readSet.reads else { return XCTFail("\(readSet.reads)") }
        XCTAssertEqual(try names(readSet), [["m1", "m2", "m3", "p1/1", "p1/2", "p2/1", "p2/2"]])
        XCTAssertNil(readSet.concatenation, "one file needs no join")
        XCTAssertTrue(readSet.changesTheRun, "the run records why every read is single")
        let reason = try XCTUnwrap(readSet.plan.singleReadReason)
        XCTAssertTrue(reason.contains("cannot pair part of a sample"), reason)
        XCTAssertTrue(readSet.plan.sampleHoldsPairsAndSingleReads)
    }

    /// L5c and L5d. The files of a merge and of a repair derivative are joined
    /// into one file. Nothing is left out and nothing is read twice.
    func testAMergeAndARepairDerivativeAreJoinedIntoOneFileOfEveryRead() async throws {
        let cases: [(URL, Set<String>, Set<String>)] = [
            (fixtures.mergeDerivative, ["u1/1", "u1/2", "x1", "x2", "x3"], ["merged.fastq", "unmerged_R1.fastq", "unmerged_R2.fastq"]),
            (fixtures.repairDerivative, ["o1", "r1/1", "r1/2", "r2/1", "r2/2"], ["repaired_R1.fastq", "repaired_R2.fastq", "singletons.fastq"]),
        ]
        for (bundle, reads, members) in cases {
            let readSet = try await plan(bundle)
            guard case .singleEnd(let joined) = readSet.reads else { return XCTFail("\(readSet.reads)") }
            let recorded = try names(readSet)
            XCTAssertEqual(recorded.count, 1, bundle.lastPathComponent)
            XCTAssertEqual(recorded.first?.count, reads.count, "no read is read twice: \(bundle.lastPathComponent)")
            XCTAssertEqual(Set(recorded.first ?? []), reads, bundle.lastPathComponent)
            let join = try XCTUnwrap(readSet.concatenation, bundle.lastPathComponent)
            XCTAssertEqual(Set(join.memberURLs.map(\.lastPathComponent)), members, bundle.lastPathComponent)
            XCTAssertEqual(join.outputURL.standardizedFileURL, joined.standardizedFileURL)
            XCTAssertNotNil(SequenceInputConcatenation.load(for: joined), "the sidecar sits beside the joined file")
            XCTAssertNotNil(readSet.plan.singleReadReason, bundle.lastPathComponent)
            XCTAssertNotNil(readSet.writeStartedAt, "a join is a write the provenance records")
            XCTAssertEqual(readSet.resolvedInputs.inputs.first?.concatenatedFrom.count, 3, bundle.lastPathComponent)
        }
    }

    // MARK: - Chunks of single reads are joined

    /// L4. Chunks of one run are single reads, so the join says nothing about
    /// pairs, and the chunks stay in the order the bundle records.
    func testAChunkedRootIsJoinedInChunkOrder() async throws {
        let readSet = try await plan(fixtures.chunkedRoot)
        XCTAssertEqual(try names(readSet), [["c1", "c2", "c3"]])
        let join = try XCTUnwrap(readSet.concatenation)
        XCTAssertEqual(join.memberURLs.map(\.lastPathComponent), ["run_0.fastq", "run_1.fastq"])
        XCTAssertNil(readSet.plan.singleReadReason)
        XCTAssertTrue(readSet.changesTheRun, "the run records the join")
    }

    /// D9. Nanopore chunks named like mates, and chunks of an unknown platform
    /// named like mates, are single reads.
    func testChunksOfALongReadOrUnknownPlatformRunAreJoinedNotPaired() async throws {
        for bundle in [fixtures.nanoporeChunkedRoot, fixtures.unknownPlatformChunkedRoot] {
            let readSet = try await plan(bundle)
            guard case .singleEnd = readSet.reads else { return XCTFail("\(bundle.lastPathComponent): \(readSet.reads)") }
            XCTAssertEqual(readSet.executionURLs.count, 1, bundle.lastPathComponent)
            XCTAssertNotNil(readSet.concatenation, bundle.lastPathComponent)
        }
    }

    // MARK: - Virtual bundles

    /// L6. A virtual bundle is materialized, never read from its preview.
    func testAVirtualSubsetIsReadFromItsMaterializedFile() async throws {
        let single = try await plan(fixtures.subsetOfSingle)
        XCTAssertEqual(try names(single), [["s1", "s3"]])
        XCTAssertNil(single.plan.singleReadReason)
        XCTAssertTrue(single.resolvedInputs.inputs.first?.wasMaterialized ?? false)
        XCTAssertNotNil(single.writeStartedAt)
        XCTAssertNil(single.concatenation, "a materialized bundle is one file")

        let merge = try await plan(fixtures.subsetOfMerge)
        XCTAssertEqual(try names(merge), [["u1/1", "u1/2", "x1"]])
        XCTAssertNotNil(merge.plan.singleReadReason, "a subset of a merge derivative mixes a pair with a merged read")

        let interleaved = try await plan(fixtures.subsetOfInterleaved)
        guard case .interleaved = interleaved.reads else { return XCTFail("\(interleaved.reads)") }
        XCTAssertEqual(try names(interleaved), [["i1/1", "i1/2"]])
    }

    /// The child of a repair derivative carries only `repair` in its lineage,
    /// and it is still read as a mix of pairs and orphans, never as strict pairs.
    func testAVirtualChildOfARepairDerivativeIsPlannedAsMixed() async throws {
        let readSet = try await plan(fixtures.subsetOfRepair)
        guard case .singleEnd = readSet.reads else { return XCTFail("\(readSet.reads)") }
        XCTAssertNotNil(readSet.plan.singleReadReason)
        XCTAssertEqual(try names(readSet), [["r1/1", "r1/2", "r2/1", "r2/2"]])
    }

    // MARK: - What the planner refuses

    /// A tool takes one pair per sample, so a bundle of two pairs of files
    /// stops the run and does not leave a pair out.
    func testSeveralPairsOfFilesAreRefused() async throws {
        let bundle = try twoPairBundle()
        do {
            _ = try await plan(bundle)
            XCTFail("a bundle of two pairs of files must be refused")
        } catch let error as SamplesheetReadSetPlannerError {
            XCTAssertEqual(error, .severalMatePairs(count: 2))
            XCTAssertTrue(error.localizedDescription.contains("2 separate R1 and R2 pairs"), error.localizedDescription)
        }
    }

    func testABundleWithNoReadsIsRefused() async throws {
        let bundle = root.appendingPathComponent("empty.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        do {
            _ = try await plan(bundle)
            XCTFail("a bundle with no reads must be refused")
        } catch let error as ReadSetResolverError {
            XCTAssertEqual(error, .noReads(path: bundle.standardizedFileURL.path))
        }
    }

    // MARK: - Preview

    /// The wizard shows what the planner will do from metadata and a header
    /// scan, and writes nothing.
    func testPreviewNamesWhatThePlannerWillDoAndWritesNothing() async throws {
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let cases: [(String, URL, SamplesheetReadSetPreview)] = [
            ("L1", fixtures.singleRoot, .singleReads),
            ("L2", fixtures.interleavedRoot, .interleavedPairs),
            ("L3", fixtures.mixedRoot, .pairs(withSingleReads: true)),
            ("L4", fixtures.chunkedRoot, .severalFiles),
            ("L4 named pair", fixtures.namedPairChunkedRoot, .pairs(withSingleReads: false)),
            ("L5b", fixtures.pairedDerivative, .pairs(withSingleReads: false)),
            ("L5c", fixtures.mergeDerivative, .pairs(withSingleReads: true)),
            ("L5d", fixtures.repairDerivative, .pairs(withSingleReads: true)),
            ("L6 of single", fixtures.subsetOfSingle, .singleReads),
            ("L6 of merge", fixtures.subsetOfMerge, .decidedAtRunTime),
        ]
        for (shape, bundle, expected) in cases {
            let preview = await SamplesheetReadSetPlanner.preview(input: bundle)
            XCTAssertEqual(preview, expected, shape)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), before, "the preview wrote nothing")
        XCTAssertFalse(SamplesheetReadSetPreview.singleReads.plansReadSet)
        XCTAssertFalse(SamplesheetReadSetPreview.interleavedPairs.plansReadSet)
        for preview in [SamplesheetReadSetPreview.pairs(withSingleReads: true), .pairs(withSingleReads: false), .severalFiles, .decidedAtRunTime] {
            XCTAssertTrue(preview.plansReadSet, "\(preview) needs the planner to reproduce the run")
        }
    }

    // MARK: - The one input a command plans

    func testPlannableInputIsOneBundleOrOneFile() throws {
        XCTAssertEqual(SamplesheetReadSetPlanner.plannableInput([fixtures.singleRoot]), fixtures.singleRoot.standardizedFileURL)
        XCTAssertNil(SamplesheetReadSetPlanner.plannableInput([]))
        XCTAssertNil(SamplesheetReadSetPlanner.plannableInput([fixtures.singleRoot, fixtures.interleavedRoot]))
        XCTAssertNil(SamplesheetReadSetPlanner.plannableInput([fixtures.importsURL]), "a folder that is not a bundle")
        XCTAssertNil(SamplesheetReadSetPlanner.plannableInput([root.appendingPathComponent("missing.fastq")]))
        let file = root.appendingPathComponent("loose.fastq")
        try ReadSetFixtures.fastq(["a"]).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(SamplesheetReadSetPlanner.plannableInput([file]), file.standardizedFileURL)
    }

    func testBothToolsDeclarePairsOnlyWhenAllPaired() {
        XCTAssertEqual(SamplesheetReadSetPlanner.capability(for: "classify.esviritu"), .pairsOnlyWhenAllPaired)
        XCTAssertEqual(SamplesheetReadSetPlanner.capability(for: "classify.taxtriage"), .pairsOnlyWhenAllPaired)
        XCTAssertEqual(EsVirituConfig.readPairingConsumerID, "classify.esviritu")
    }

    // MARK: - Helpers

    /// A merge-style derivative whose manifest records two R1 and R2 pairs of files.
    private func twoPairBundle() throws -> URL {
        let bundle = root.appendingPathComponent("two-pairs.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for (name, read) in [("a_R1", "a/1"), ("a_R2", "a/2"), ("b_R1", "b/1"), ("b_R2", "b/2")] {
            try ReadSetFixtures.fastq([read]).write(to: bundle.appendingPathComponent("\(name).fastq"), atomically: true, encoding: .utf8)
        }
        let classification = ReadClassification(files: [
            .init(filename: "a_R1.fastq", role: .pairedR1, readCount: 1),
            .init(filename: "a_R2.fastq", role: .pairedR2, readCount: 1),
            .init(filename: "b_R1.fastq", role: .pairedR1, readCount: 1),
            .init(filename: "b_R2.fastq", role: .pairedR2, readCount: 1),
        ])
        let operation = FASTQDerivativeOperation(kind: .pairedEndRepair)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "two-pairs",
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: "a_R1.fastq",
                payload: .fullMixed(classification),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 4, baseCount: 40),
                pairingMode: .pairedEnd,
                readClassification: nil,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        return bundle
    }
}
