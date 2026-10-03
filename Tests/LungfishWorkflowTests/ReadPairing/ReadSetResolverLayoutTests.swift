// ReadSetResolverLayoutTests.swift - The read-set plan of every bundle layout
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// One test per layout row of docs/contracts/READ-PAIRING.md, planned for a
// tool that takes pairs and single reads as separate files (bowtie2,
// SPAdes, Kraken2). Each checks the pairs, the single reads with roles,
// the fragment counts and the steps.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class ReadSetResolverLayoutTests: XCTestCase {
    private var root: URL!
    private var fixtures: ReadSetFixtures!
    private var workDirectory: URL!
    private var resolver: ReadSetResolver!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "read-set-layouts")
        fixtures = try ReadSetFixtures(in: root)
        workDirectory = root.appendingPathComponent("work", isDirectory: true)
        resolver = ReadSetResolver(materializationDirectory: workDirectory, materializer: fixtures.materializer)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func plan(_ url: URL, _ capability: ReadPairingCapability = .bothInOneRunAsSeparateFiles) async throws -> ReadSetPlan {
        try await resolver.plan(for: url, capability: capability)
    }

    private func names(_ url: URL) throws -> [String] {
        try ReadSetFixtures.readNames(in: url)
    }

    private func separate(_ pair: ReadSetMatePair?, file: StaticString = #filePath, line: UInt = #line) throws -> (r1: URL, r2: URL) {
        guard case .separate(let r1, let r2) = try XCTUnwrap(pair, file: file, line: line).files else {
            XCTFail("expected separate R1 and R2 files", file: file, line: line)
            throw XCTSkip("not separate")
        }
        return (r1, r2)
    }

    // MARK: - Roots

    func testSingleEndRootIsSingleReadsWithNoStep() async throws {
        let plan = try await plan(fixtures.singleRoot)
        XCTAssertEqual(plan.sourceLayout, .singleEndFile)
        XCTAssertTrue(plan.matePairs.isEmpty)
        XCTAssertEqual(plan.singleReads.map(\.role), [.singleEnd])
        XCTAssertEqual(try names(plan.singleReads[0].url), ["s1", "s2", "s3"])
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertTrue(plan.recordsNothingNew)
        XCTAssertEqual(plan.provenanceParameters, [:])
    }

    func testInterleavedRootIsOneInterleavedMatePairWithNoStep() async throws {
        let plan = try await plan(fixtures.interleavedRoot)
        XCTAssertEqual(plan.sourceLayout, .interleavedFile)
        XCTAssertEqual(plan.matePairs.map(\.files), [.interleaved(fixtures.interleavedRoot.appendingPathComponent("reads.fastq").standardizedFileURL)])
        XCTAssertTrue(plan.singleReads.isEmpty)
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertTrue(plan.recordsNothingNew)
    }

    func testMixedRootIsSplitByNameIntoPairsAndMergedReads() async throws {
        let plan = try await plan(fixtures.mixedRoot)
        XCTAssertEqual(plan.sourceLayout, .mixedFile)
        XCTAssertTrue(plan.sampleHoldsPairsAndSingleReads)
        let pair = try separate(plan.matePairs.first)
        XCTAssertEqual(try names(pair.r1), ["p1/1", "p2/1"])
        XCTAssertEqual(try names(pair.r2), ["p1/2", "p2/2"])
        XCTAssertEqual(plan.singleReads.map(\.role), [.merged], "the sidecar records merged reads and no orphans")
        XCTAssertEqual(try names(plan.singleReads[0].url), ["m1", "m2", "m3"])
        XCTAssertEqual(plan.steps.map(\.kind), [.splitByName])
        XCTAssertEqual(plan.steps[0].pairCount, 2)
        XCTAssertEqual(plan.steps[0].singleReadCount, 3)
        XCTAssertEqual(plan.composition.pairedFragments, 2)
        XCTAssertEqual(plan.composition.mergedReads, 3)
        XCTAssertEqual(plan.composition.fragmentCount, 5)
        XCTAssertFalse(plan.recordsNothingNew)
        XCTAssertNotNil(plan.provenanceParameters["readSetPlan"])
        XCTAssertTrue(plan.executionURLs.allSatisfy { $0.path.hasPrefix(workDirectory.standardizedFileURL.path + "/") })
    }

    func testChunkedRootIsEveryChunkAsSingleReads() async throws {
        let plan = try await plan(fixtures.chunkedRoot)
        XCTAssertEqual(plan.sourceLayout, .multiFileRoot)
        XCTAssertTrue(plan.matePairs.isEmpty)
        XCTAssertEqual(plan.singleReads.map { $0.url.lastPathComponent }, ["run_0.fastq", "run_1.fastq"])
        XCTAssertEqual(Set(plan.singleReads.map(\.role)), [.singleEnd])
        XCTAssertTrue(plan.recordsNothingNew)
    }

    /// D9. Two chunks of an Oxford Nanopore import named `x_1` and `x_2`
    /// match the R1 and R2 file-name rule, which pairs them today in
    /// ResolvedSequenceInputs. Long reads are never paired.
    func testNanoporeChunksNamedLikeMatesAreNeverPaired() async throws {
        let plan = try await plan(fixtures.nanoporeChunkedRoot)
        XCTAssertEqual(plan.sequencingPlatform, .oxfordNanopore)
        XCTAssertTrue(plan.matePairs.isEmpty)
        XCTAssertEqual(plan.singleReads.map { $0.url.lastPathComponent }, ["x_1.fastq", "x_2.fastq"])
        XCTAssertEqual(Set(plan.singleReads.map(\.role)), [.singleEnd])
        XCTAssertTrue(plan.recordsNothingNew)
    }

    func testShortReadChunksNamedAsMatesAreOnePair() async throws {
        let plan = try await plan(fixtures.namedPairChunkedRoot)
        XCTAssertEqual(plan.sourceLayout, .pairedFiles)
        let pair = try separate(plan.matePairs.first)
        XCTAssertEqual(pair.r1.lastPathComponent, "sample_R1.fastq")
        XCTAssertEqual(pair.r2.lastPathComponent, "sample_R2.fastq")
        XCTAssertTrue(plan.recordsNothingNew)
    }

    // MARK: - Physical derivatives

    func testFullDerivativeOfSingleReadsIsSingleReads() async throws {
        let plan = try await plan(fixtures.fullDerivative)
        XCTAssertEqual(plan.sourceLayout, .singleEndFile)
        XCTAssertEqual(try names(plan.singleReads[0].url), ["g1", "g2"])
        XCTAssertTrue(plan.recordsNothingNew)
    }

    /// A re-imported `fastq merge` output is a `full` derivative whose
    /// sidecar records the classification in the L3 form, so it is planned
    /// as a mixed root file.
    func testFullDerivativeWithMixedSidecarIsSplitLikeAMixedRoot() async throws {
        let plan = try await plan(fixtures.fullMergeOutput)
        XCTAssertEqual(plan.sourceLayout, .mixedFile)
        let pair = try separate(plan.matePairs.first)
        XCTAssertEqual(try names(pair.r1), ["p1/1"])
        XCTAssertEqual(try names(pair.r2), ["p1/2"])
        XCTAssertEqual(plan.singleReads.map(\.role), [.merged])
        XCTAssertEqual(try names(plan.singleReads[0].url), ["m1", "m2"])
        XCTAssertEqual(plan.steps.map(\.kind), [.splitByName])
        XCTAssertEqual(plan.composition.fragmentCount, 3)
    }

    func testFullDerivativeWithoutSidecarIsScannedAsBefore() async throws {
        let plan = try await plan(fixtures.fullUnlabelled)
        XCTAssertEqual(plan.sourceLayout, .interleavedFile)
        XCTAssertEqual(plan.matePairs.map(\.urls), [[fixtures.fullUnlabelled.appendingPathComponent("reads.fastq").standardizedFileURL]])
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertTrue(plan.recordsNothingNew)
    }

    func testPairedDerivativeIsOneMatePair() async throws {
        let plan = try await plan(fixtures.pairedDerivative)
        XCTAssertEqual(plan.sourceLayout, .pairedFiles)
        let pair = try separate(plan.matePairs.first)
        XCTAssertEqual(pair.r1.lastPathComponent, "sample_R1.fastq")
        XCTAssertEqual(pair.r2.lastPathComponent, "sample_R2.fastq")
        XCTAssertTrue(plan.singleReads.isEmpty)
        XCTAssertTrue(plan.recordsNothingNew)
    }

    /// Red before the resolver. ResolvedSequenceInputs joins the three files
    /// of a merge derivative into one single-end file, so its pair is never
    /// a pair.
    func testMergeDerivativeKeepsItsRoles() async throws {
        let plan = try await plan(fixtures.mergeDerivative)
        XCTAssertEqual(plan.sourceLayout, .mixedDerivative)
        let pair = try separate(plan.matePairs.first)
        XCTAssertEqual(pair.r1.lastPathComponent, "unmerged_R1.fastq")
        XCTAssertEqual(pair.r2.lastPathComponent, "unmerged_R2.fastq")
        XCTAssertEqual(plan.matePairs.first?.pairCount, 1)
        XCTAssertEqual(plan.singleReads.map(\.url.lastPathComponent), ["merged.fastq"])
        XCTAssertEqual(plan.singleReads.map(\.role), [.merged])
        XCTAssertTrue(plan.steps.isEmpty, "the roles are separate files already")
        XCTAssertTrue(plan.sampleHoldsPairsAndSingleReads)
        XCTAssertEqual(plan.composition, ReadSetComposition(pairedFragments: 1, mergedReads: 3, orphanReads: 0, singleEndReads: 0, mergedOrOrphanReads: 0))
        XCTAssertEqual(plan.composition.fragmentCount, 4)
        XCTAssertFalse(plan.recordsNothingNew)
    }

    func testRepairDerivativeGivesPairsAndOrphans() async throws {
        let plan = try await plan(fixtures.repairDerivative)
        XCTAssertEqual(plan.sourceLayout, .mixedDerivative)
        let pair = try separate(plan.matePairs.first)
        XCTAssertEqual(pair.r1.lastPathComponent, "repaired_R1.fastq")
        XCTAssertEqual(plan.singleReads.map(\.url.lastPathComponent), ["singletons.fastq"])
        XCTAssertEqual(plan.singleReads.map(\.role), [.orphan])
        XCTAssertEqual(plan.composition.fragmentCount, 3)
    }

    /// D3 in the resolver. A role file the manifest records but the disk
    /// lacks stops the plan instead of leaving its reads out.
    func testMergeDerivativeMissingAMateFileThrows() async throws {
        try FileManager.default.removeItem(at: fixtures.mergeDerivative.appendingPathComponent("unmerged_R2.fastq"))
        do {
            _ = try await plan(fixtures.mergeDerivative)
            XCTFail("a missing R2 file must stop the plan")
        } catch let error as ReadSetResolverError {
            guard case .missingFile(_, let filePath) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(filePath.hasSuffix("unmerged_R2.fastq"))
        }
    }

    func testFASTADerivativeIsSingleRecordsInPlace() async throws {
        let plan = try await plan(fixtures.fastaDerivative)
        XCTAssertEqual(plan.sourceLayout, .fasta)
        XCTAssertEqual(plan.singleReads.map(\.url.lastPathComponent), ["converted.fasta"])
        XCTAssertTrue(plan.recordsNothingNew)
    }

    // MARK: - Virtual derivatives

    func testVirtualSubsetOfSingleReadsIsMaterializedSingleReads() async throws {
        let plan = try await plan(fixtures.subsetOfSingle)
        XCTAssertTrue(plan.wasMaterialized)
        XCTAssertEqual(plan.sourceLayout, .singleEndFile)
        XCTAssertEqual(try names(plan.singleReads[0].url), ["s1", "s3"])
        XCTAssertTrue(plan.recordsNothingNew)
    }

    func testVirtualSubsetOfInterleavedPairsIsAnInterleavedPair() async throws {
        let plan = try await plan(fixtures.subsetOfInterleaved)
        XCTAssertTrue(plan.wasMaterialized)
        XCTAssertEqual(plan.sourceLayout, .interleavedFile)
        XCTAssertEqual(plan.matePairs.count, 1)
        XCTAssertTrue(plan.recordsNothingNew)
    }

    func testVirtualSubsetOfMergeDerivativeIsSplitByName() async throws {
        let plan = try await plan(fixtures.subsetOfMerge)
        XCTAssertTrue(plan.wasMaterialized)
        XCTAssertEqual(plan.sourceLayout, .mixedFile)
        let pair = try separate(plan.matePairs.first)
        XCTAssertEqual(try names(pair.r1), ["u1/1"])
        XCTAssertEqual(try names(pair.r2), ["u1/2"])
        XCTAssertEqual(plan.singleReads.map(\.role), [.merged], "the parent's roles say the single reads are merged")
        XCTAssertEqual(try names(plan.singleReads[0].url), ["x1"])
    }

    /// A virtual child of a repair derivative names only `repair` in its
    /// lineage, so its own metadata shows no single reads, and a subset
    /// holding only pairs scans as strict pairs. The parent's roles record
    /// orphans, so the resolver plans it as mixed and splits it by name.
    func testVirtualSubsetOfRepairDerivativeIsPlannedFromTheParentRoles() async throws {
        let ownHints = FASTQReadLayoutClassifier.metadataHints(for: fixtures.subsetOfRepair)
        XCTAssertFalse(ownHints.hasMergedOrUnpairedReads, "the fixture must reproduce the gap")

        let plan = try await plan(fixtures.subsetOfRepair)
        XCTAssertEqual(plan.sourceLayout, .mixedFile)
        XCTAssertTrue(plan.layoutReason.contains("merged or unpaired"), plan.layoutReason)
        let pair = try separate(plan.matePairs.first)
        XCTAssertEqual(try names(pair.r1), ["r1/1", "r2/1"])
        XCTAssertEqual(try names(pair.r2), ["r1/2", "r2/2"])
        XCTAssertTrue(plan.singleReads.isEmpty)

        let streamPlan = try await self.plan(fixtures.subsetOfRepair, .bothInOneRunAsNameInterleavedStream)
        XCTAssertEqual(streamPlan.mixedStreams.map(\.singleReadRole), [.orphan])
    }

    func testDemultiplexGroupThrowsAndLeavesNoFiles() async throws {
        do {
            _ = try await plan(fixtures.demuxGroup)
            XCTFail("a demultiplex group holds no reads")
        } catch is ReadSetFixtures.StubMaterializer.Unsupported {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDirectory.path))
    }
}
