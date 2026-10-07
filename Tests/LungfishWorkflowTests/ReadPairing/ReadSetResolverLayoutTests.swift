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

    /// Lead A F3. After lane B1 a CLI import with unrecognised headers
    /// records `unknown`, and no importer writes a paired chunked root, so
    /// chunks pair by name only when a short-read platform is recorded.
    func testChunkedRootWithUnknownPlatformStaysSingleReads() async throws {
        let plan = try await plan(fixtures.unknownPlatformChunkedRoot)
        XCTAssertEqual(plan.sequencingPlatform, .unknown)
        XCTAssertEqual(plan.sourceLayout, .multiFileRoot)
        XCTAssertTrue(plan.matePairs.isEmpty)
        XCTAssertEqual(plan.singleReads.map { $0.url.lastPathComponent }, ["x_1.fastq", "x_2.fastq"])
    }

    func testChunkedRootWithNoPlatformStaysSingleReads() async throws {
        try FileManager.default.removeItem(at: FASTQMetadataStore.metadataURL(
            for: fixtures.namedPairChunkedRoot.appendingPathComponent("chunks/sample_R1.fastq")
        ))
        let plan = try await plan(fixtures.namedPairChunkedRoot)
        XCTAssertNil(plan.sequencingPlatform)
        XCTAssertTrue(plan.matePairs.isEmpty)
        XCTAssertEqual(plan.singleReads.count, 2)
    }

    /// A root that is not chunked and holds exactly two files named as
    /// mates keeps the file-name rule, whatever the platform records.
    func testLegacyRootWithTwoNamedFilesIsOnePair() async throws {
        let legacy = fixtures.importsURL.appendingPathComponent("legacy-pair.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try ReadSetFixtures.fastq(["w1/1"]).write(to: legacy.appendingPathComponent("w_R1.fastq"), atomically: true, encoding: .utf8)
        try ReadSetFixtures.fastq(["w1/2"]).write(to: legacy.appendingPathComponent("w_R2.fastq"), atomically: true, encoding: .utf8)
        let plan = try await plan(legacy)
        XCTAssertEqual(plan.sourceLayout, .pairedFiles)
        XCTAssertEqual(plan.matePairs.count, 1)
    }

    /// Lead A F1. A root whose only FASTQ is the preview is never planned
    /// as the sample, which would analyse a 1,000-read subset silently.
    func testRootHoldingOnlyThePreviewThrows() async throws {
        let previewOnly = fixtures.importsURL.appendingPathComponent("preview-only.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: previewOnly, withIntermediateDirectories: true)
        try ReadSetFixtures.fastq(["z1"]).write(to: previewOnly.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        do {
            _ = try await plan(previewOnly)
            XCTFail("a preview is not the sample")
        } catch let error as ReadSetResolverError {
            guard case .noReads = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDirectory.path))
    }

    /// Lead A F2. A materialized file that ends inside a record stops the
    /// plan instead of being read as single reads.
    func testTruncatedMaterializationThrows() async throws {
        let truncated = ReadSetFixtures.StubMaterializer(readsByBundlePath: [
            fixtures.subsetOfSingle.standardizedFileURL.path: ReadSetFixtures.fastq(["s1"]) + "@s3\nACGT\n",
        ])
        let resolver = ReadSetResolver(materializationDirectory: workDirectory, materializer: truncated)
        do {
            _ = try await resolver.plan(for: fixtures.subsetOfSingle, capability: .bothInOneRunAsSeparateFiles)
            XCTFail("a truncated materialization must stop the plan")
        } catch is FASTQPairInterleaver.InterleaveError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDirectory.path))
    }

    /// Lead A follow-on to F2, the D2 shape. A materialization whose first
    /// 100,000 records alternate mates scans as strict, but single reads
    /// follow past the scan limit. The whole-file count shows them, so the
    /// file is mixed and no single read is planned as half of a pair.
    func testPairsBeyondTheScanLimitFollowedBySingleReadsAreMixed() async throws {
        let pairNames = (0..<50_001).flatMap { ["d\($0)/1", "d\($0)/2"] }
        let reads = ReadSetFixtures.fastq(pairNames) + ReadSetFixtures.fastq(["merged-a", "merged-b", "merged-c"])
        let materializer = ReadSetFixtures.StubMaterializer(readsByBundlePath: [
            fixtures.subsetOfSingle.standardizedFileURL.path: reads,
        ])
        let resolver = ReadSetResolver(materializationDirectory: workDirectory, materializer: materializer)

        let separate = try await resolver.plan(for: fixtures.subsetOfSingle, capability: .bothInOneRunAsSeparateFiles)
        XCTAssertEqual(separate.sourceLayout, .mixedFile)
        XCTAssertEqual(separate.steps.map(\.kind), [.splitByName])
        XCTAssertEqual(separate.matePairs.first?.pairCount, 50_001)
        XCTAssertEqual(separate.singleReads.map(\.readCount), [3])
        XCTAssertEqual(try names(XCTUnwrap(separate.singleReads.first).url), ["merged-a", "merged-b", "merged-c"])
        XCTAssertEqual(separate.composition.fragmentCount, 50_004)

        let samplesheet = try await resolver.plan(for: fixtures.subsetOfSingle, capability: .pairsOnlyWhenAllPaired)
        XCTAssertEqual(samplesheet.sourceLayout, .mixedFile)
        XCTAssertTrue(samplesheet.matePairs.isEmpty)
        XCTAssertEqual(samplesheet.singleReads.map(\.readCount), [100_005])
        XCTAssertNotNil(samplesheet.singleReadReason)
    }

    func testUnreadableMaterializationThrows() async throws {
        struct Vanishing: CLISequenceInputMaterializing, Sendable {
            func materialize(bundleURL: URL, tempDirectory: URL, progress: (@Sendable (String) -> Void)?) async throws -> URL {
                tempDirectory.appendingPathComponent("never-written.fastq")
            }
        }
        let resolver = ReadSetResolver(materializationDirectory: workDirectory, materializer: Vanishing())
        do {
            _ = try await resolver.plan(for: fixtures.subsetOfSingle, capability: .bothInOneRunAsSeparateFiles)
            XCTFail("an unreadable materialization must stop the plan")
        } catch {
        }
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

    /// A `full` derivative of a merge bundle written before such outputs
    /// recorded their counts, holding `reads` and no count beside them.
    private func uncountedMergeLineageChild(_ name: String, reads: [String]) throws -> URL {
        let bundle = fixtures.importsURL.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try ReadSetFixtures.fastq(reads).write(to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .lengthFilter)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: name,
                parentBundleRelativePath: "@/Imports/\(fixtures.mergeDerivative.lastPathComponent)",
                rootBundleRelativePath: ".",
                rootFASTQFilename: "reads.fastq",
                payload: .full(fastqFilename: "reads.fastq"),
                lineage: [FASTQDerivativeOperation(kind: .pairedEndMerge), operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: reads.count, baseCount: Int64(reads.count * 10)),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        return bundle
    }

    /// S4's no-count case for a bundle that is not virtual (Phase 2.1 lane
    /// L3, after the ruling on option 1). The merge in its lineage made the
    /// layout scan call adjacent mates mixed, so a tool that pairs only a
    /// wholly paired sample ran a file of only pairs single-end. A scan that
    /// read the whole file counted every record, so it outranks that merge.
    /// The plan and the layout every other consumer reads agree that the file
    /// is one interleaved pair. A file that also holds a read without its
    /// mate stays mixed.
    func testAPhysicalFileOfOnlyPairsFromAMergeLineageWithNoCountIsAnInterleavedPair() async throws {
        let pairsOnly = try uncountedMergeLineageChild("legacy-pairs", reads: ["u1/1", "u1/2", "u2/1", "u2/2"])
        let pairs = try await plan(pairsOnly, .pairsOnlyWhenAllPaired)
        XCTAssertEqual(pairs.sourceLayout, .interleavedFile)
        XCTAssertNil(pairs.singleReadReason)
        XCTAssertEqual(pairs.matePairs.count, 1)
        XCTAssertTrue(pairs.singleReads.isEmpty)
        XCTAssertTrue(pairs.recordsNothingNew)
        XCTAssertEqual(FASTQInputLayoutResolver.resolve(inputURLs: [pairsOnly]).layout, .strictlyInterleaved)

        let mixed = try uncountedMergeLineageChild("legacy-mixed", reads: ["u1/1", "u1/2", "x1"])
        let mixedPlan = try await plan(mixed, .pairsOnlyWhenAllPaired)
        XCTAssertEqual(mixedPlan.sourceLayout, .mixedFile)
        XCTAssertNotNil(mixedPlan.singleReadReason)
        XCTAssertTrue(mixedPlan.matePairs.isEmpty)
        XCTAssertEqual(FASTQInputLayoutResolver.resolve(inputURLs: [mixed]).layout, .mixedMergedAndPairs)
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
    /// lineage, so its own metadata shows no single reads. The parent's
    /// roles record orphans, so the reads without a mate in a child that
    /// holds pairs and single reads are orphans.
    func testVirtualSubsetOfRepairDerivativeIsPlannedFromTheParentRoles() async throws {
        let ownHints = FASTQReadLayoutClassifier.metadataHints(for: fixtures.subsetOfRepair)
        XCTAssertFalse(ownHints.hasMergedOrUnpairedReads, "the fixture must reproduce the gap")

        let materialized = ["r1/1", "r1/2", "r2/1", "r2/2", "o1"]
        let plan = try await plan(fixtures.subsetOfRepair, materialized: materialized)
        XCTAssertEqual(plan.sourceLayout, .mixedFile)
        let pair = try separate(plan.matePairs.first)
        XCTAssertEqual(try names(pair.r1), ["r1/1", "r2/1"])
        XCTAssertEqual(try names(pair.r2), ["r1/2", "r2/2"])
        XCTAssertEqual(plan.singleReads.map(\.role), [.orphan], "the parent's roles say the single reads are orphans")

        let streamPlan = try await self.plan(fixtures.subsetOfRepair, materialized: materialized, .bothInOneRunAsNameInterleavedStream)
        XCTAssertEqual(streamPlan.mixedStreams.map(\.singleReadRole), [.orphan])
    }

    /// Final review A, S4. A materialized file is counted whole, and a file
    /// is mixed only when it holds pairs and single reads. The repair child
    /// that holds only pairs r1 and r2, and a subset of the merge derivative
    /// that kept only the unmerged pair u1, are pairs whatever their merge
    /// or repair lineage says. They used to be planned as mixed, so EsViritu,
    /// TaxTriage and Viral Recon ran their mates as single reads and stated
    /// that the sample held single reads.
    func testAVirtualSubsetHoldingOnlyPairsIsAnInterleavedPairWhateverItsLineageSays() async throws {
        let cases: [(String, URL, [String])] = [
            ("repair child", fixtures.subsetOfRepair, ["r1/1", "r1/2", "r2/1", "r2/2"]),
            ("merge subset", fixtures.subsetOfMerge, ["u1/1", "u1/2"]),
        ]
        for (label, bundle, materialized) in cases {
            for capability in [ReadPairingCapability.bothInOneRunAsSeparateFiles, .pairsOnlyWhenAllPaired, .bothInOneRunAsNameInterleavedStream] {
                let plan = try await plan(bundle, materialized: materialized, capability)
                XCTAssertTrue(plan.wasMaterialized, label)
                XCTAssertEqual(plan.sourceLayout, .interleavedFile, "\(label): \(plan.layoutReason)")
                XCTAssertTrue(plan.layoutReason.contains("no read without a mate"), "\(label): \(plan.layoutReason)")
                XCTAssertFalse(plan.sampleHoldsPairsAndSingleReads, label)
                XCTAssertEqual(plan.matePairs.count, 1, label)
                guard case .interleaved(let url) = plan.matePairs.first?.files else { return XCTFail("\(label): \(plan.matePairs)") }
                XCTAssertEqual(try names(url), materialized, label)
                XCTAssertTrue(plan.singleReads.isEmpty, label)
                XCTAssertTrue(plan.mixedStreams.isEmpty, label)
                XCTAssertNil(plan.singleReadReason, label)
                XCTAssertTrue(plan.recordsNothingNew, label)
                XCTAssertEqual(plan.composition.pairedFragments, materialized.count / 2, label)
            }
        }
    }

    /// A subset of the merge derivative that kept only merged reads holds no
    /// pair, so it is single reads, merged by the parent's roles, and the plan
    /// writes no split.
    func testAVirtualSubsetHoldingNoPairIsSingleReadsWithTheParentsRole() async throws {
        let plan = try await plan(fixtures.subsetOfMerge, materialized: ["x1", "x2"])
        XCTAssertEqual(plan.sourceLayout, .singleEndFile, plan.layoutReason)
        XCTAssertFalse(plan.sampleHoldsPairsAndSingleReads)
        XCTAssertTrue(plan.matePairs.isEmpty)
        XCTAssertTrue(plan.mixedStreams.isEmpty)
        XCTAssertEqual(plan.singleReads.map(\.role), [.merged])
        XCTAssertEqual(plan.singleReads.map(\.readCount), [2])
        XCTAssertEqual(try names(plan.singleReads[0].url), ["x1", "x2"])
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertEqual(plan.composition.mergedReads, 2)
    }

    /// Plans `bundle` with a materializer that writes `reads` for it.
    private func plan(
        _ bundle: URL,
        materialized reads: [String],
        _ capability: ReadPairingCapability = .bothInOneRunAsSeparateFiles
    ) async throws -> ReadSetPlan {
        let materializer = ReadSetFixtures.StubMaterializer(readsByBundlePath: [
            bundle.standardizedFileURL.path: ReadSetFixtures.fastq(reads),
        ])
        return try await ReadSetResolver(materializationDirectory: workDirectory, materializer: materializer)
            .plan(for: bundle, capability: capability)
    }

    func testDemultiplexGroupThrowsAndLeavesNoFiles() async throws {
        do {
            _ = try await plan(fixtures.demuxGroup)
            XCTFail("a demultiplex group holds no reads")
        } catch is ReadSetFixtures.StubMaterializer.Unsupported {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDirectory.path))
    }

    // MARK: - Named inputs (Phase 2.1 round F4, review A S1)

    private func plan(named url: URL, progress: (@Sendable (String) -> Void)? = nil) async throws -> ReadSetPlan {
        try await resolver.plan(for: ReadSetNamedInput(url), capability: .bothInOneRunAsSeparateFiles, progress: progress)
    }

    /// A bundle and a file outside every bundle are read as named, a file
    /// inside a bundle as that file alone, and the preview of a virtual
    /// bundle, a few reads of the sample, as its bundle.
    func testANamedInputIsReadWhereItLies() throws {
        let merged = fixtures.mergeDerivative.appendingPathComponent("merged.fastq")
        let missing = fixtures.mergeDerivative.appendingPathComponent("not-there.fastq")
        let preview = fixtures.subsetOfMerge.appendingPathComponent("preview.fastq")
        let loose = root.appendingPathComponent("loose.fastq")
        try ReadSetFixtures.fastq(["l1"]).write(to: loose, atomically: true, encoding: .utf8)

        XCTAssertEqual(ReadSetNamedInput(fixtures.mergeDerivative), .asNamed(fixtures.mergeDerivative.standardizedFileURL))
        XCTAssertEqual(ReadSetNamedInput(loose), .asNamed(loose.standardizedFileURL))
        XCTAssertEqual(ReadSetNamedInput(merged), .fileAlone(merged.standardizedFileURL))
        XCTAssertEqual(
            ReadSetNamedInput(missing), .fileAlone(missing.standardizedFileURL),
            "a missing file inside a bundle never stands for the whole bundle"
        )
        guard case let .previewOf(bundleURL, previewURL) = ReadSetNamedInput(preview) else {
            return XCTFail("the preview of a virtual bundle stands for its bundle")
        }
        XCTAssertEqual(bundleURL.standardizedFileURL.path, fixtures.subsetOfMerge.standardizedFileURL.path)
        XCTAssertEqual(previewURL, preview.standardizedFileURL)
        XCTAssertEqual(
            ReadSetNamedInput(preview).note,
            "preview.fastq is the preview of the virtual bundle merge-subset.lungfishfastq, not its reads. Reading the bundle instead."
        )
        XCTAssertNil(ReadSetNamedInput(merged).note)
    }

    /// The merged file of a merge derivative, named alone, is its merged
    /// reads and none of the pairs beside it, with no step. The bundle's
    /// merge lineage and paired mode describe the bundle, not one of its
    /// files, so they do not make the file a mixed stream. Naming the bundle
    /// still plans every role.
    func testAFileNamedInsideAMergeDerivativeIsPlannedAlone() async throws {
        let merged = fixtures.mergeDerivative.appendingPathComponent("merged.fastq")

        let mergedPlan = try await plan(named: merged)

        XCTAssertEqual(mergedPlan.sourceLayout, .singleEndFile, mergedPlan.layoutReason)
        XCTAssertEqual(mergedPlan.inputURL, merged.standardizedFileURL)
        XCTAssertTrue(mergedPlan.matePairs.isEmpty)
        XCTAssertEqual(mergedPlan.singleReads.map(\.url), [merged.standardizedFileURL], "the file is read in place")
        XCTAssertEqual(try names(XCTUnwrap(mergedPlan.singleReads.first).url), ["x1", "x2", "x3"])
        XCTAssertTrue(mergedPlan.steps.isEmpty)
        XCTAssertTrue(mergedPlan.recordsNothingNew)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDirectory.path), "nothing was written")

        let r1 = fixtures.pairedDerivative.appendingPathComponent("sample_R1.fastq")
        let r1Plan = try await plan(named: r1)
        XCTAssertEqual(r1Plan.sourceLayout, .singleEndFile, r1Plan.layoutReason)
        XCTAssertEqual(try names(XCTUnwrap(r1Plan.singleReads.first).url), ["p1/1", "p2/1"])
        XCTAssertTrue(r1Plan.steps.isEmpty)

        let bundlePlan = try await plan(named: fixtures.mergeDerivative)
        XCTAssertEqual(bundlePlan.sourceLayout, .mixedDerivative)
        XCTAssertEqual(bundlePlan.matePairs.count, 1)
    }

    /// A file named inside a bundle is planned as a copy of it beside its own
    /// sidecar, outside every bundle, is planned. Its sidecar still counts,
    /// so an explicit single-end choice holds and a recorded merge keeps a
    /// file mixed. Only its place in the bundle is ignored. This also keeps
    /// the resolver's reading of a file alone in step with the LungfishIO
    /// rules for a file outside every bundle.
    func testAFileNamedInsideABundleIsPlannedAsItsCopyOutsideEveryBundleWouldBe() async throws {
        let explicitSingle = try bundle("explicit-single").appendingPathComponent("reads.fastq")
        try ReadSetFixtures.fastq(["e1/1", "e1/2", "e2/1", "e2/2"]).write(to: explicitSingle, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: .singleEnd, pairingSource: .explicit)),
            for: explicitSingle
        )
        // Mates in the file, but R1 and R2 counts in its sidecar that differ.
        let unmatchedCounts = try bundle("unmatched-counts").appendingPathComponent("reads.fastq")
        try ReadSetFixtures.fastq(["c1/1", "c1/2", "c2/1", "c2/2"]).write(to: unmatchedCounts, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(readClassification: ReadClassification(files: [
                .init(filename: "reads.fastq", role: .pairedR1, readCount: 2),
                .init(filename: "reads.fastq", role: .pairedR2, readCount: 1),
            ])),
            for: unmatchedCounts
        )
        // A merge recipe, outranked by the sidecar's count of only pairs.
        let countedPairs = try bundle("counted-pairs").appendingPathComponent("reads.fastq")
        try ReadSetFixtures.fastq(["d1/1", "d1/2", "d2/1", "d2/2"]).write(to: countedPairs, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(
                ingestion: IngestionMetadata(
                    pairingMode: .interleaved,
                    pairingSource: .detected,
                    recipeApplied: RecipeAppliedInfo(
                        recipeID: "vsp2",
                        recipeName: "VSP2",
                        stepResults: [RecipeStepResult(stepName: "Merge pairs", tool: "bbmerge", durationSeconds: 1)]
                    )
                ),
                readClassification: ReadClassification(files: [
                    .init(filename: "reads.fastq", role: .pairedR1, readCount: 2),
                    .init(filename: "reads.fastq", role: .pairedR2, readCount: 2),
                ])
            ),
            for: countedPairs
        )
        // A merge recipe and no count, which a scan of the whole file outranks.
        let recipeOnly = try bundle("recipe-only").appendingPathComponent("reads.fastq")
        try ReadSetFixtures.fastq(["g1/1", "g1/2"]).write(to: recipeOnly, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(
                pairingMode: .interleaved,
                recipeApplied: RecipeAppliedInfo(
                    recipeID: "vsp2",
                    recipeName: "VSP2",
                    stepResults: [RecipeStepResult(stepName: "Merge pairs", tool: "bbmerge", durationSeconds: 1)]
                )
            )),
            for: recipeOnly
        )
        let members = [
            fixtures.mergeDerivative.appendingPathComponent("merged.fastq"),
            fixtures.mergeDerivative.appendingPathComponent("unmerged_R2.fastq"),
            fixtures.pairedDerivative.appendingPathComponent("sample_R1.fastq"),
            fixtures.mixedRoot.appendingPathComponent("reads.fastq"),
            fixtures.interleavedRoot.appendingPathComponent("reads.fastq"),
            fixtures.fullMergeOutput.appendingPathComponent("reads.fastq"),
            fixtures.fastaDerivative.appendingPathComponent("converted.fasta"),
            explicitSingle,
            unmatchedCounts,
            countedPairs,
            recipeOnly,
        ]

        for (index, member) in members.enumerated() {
            let label = member.deletingLastPathComponent().lastPathComponent + "/" + member.lastPathComponent
            let copy = try looseCopy(of: member, index: index)

            let alone = try await plan(named: member)
            let loose = try await plan(copy)

            XCTAssertEqual(alone.sourceLayout, loose.sourceLayout, label)
            XCTAssertEqual(alone.layoutReason, loose.layoutReason, label)
            XCTAssertEqual(alone.composition, loose.composition, label)
            XCTAssertEqual(alone.sampleHoldsPairsAndSingleReads, loose.sampleHoldsPairsAndSingleReads, label)
            XCTAssertEqual(alone.matePairs.count, loose.matePairs.count, label)
            XCTAssertEqual(alone.singleReads.map(\.role), loose.singleReads.map(\.role), label)
            XCTAssertEqual(alone.steps.map(\.pairCount), loose.steps.map(\.pairCount), label)
            XCTAssertEqual(alone.steps.map(\.singleReadCount), loose.steps.map(\.singleReadCount), label)
            XCTAssertEqual(alone.inputURL, member.standardizedFileURL, label)
            XCTAssertEqual(alone.steps.flatMap(\.inputURLs), alone.steps.isEmpty ? [] : [member.standardizedFileURL], label)
        }
        let explicitPlan = try await plan(named: explicitSingle)
        XCTAssertEqual(explicitPlan.sourceLayout, .singleEndFile, "the explicit single-end choice in the file's own sidecar holds")
        let countedPlan = try await plan(named: countedPairs)
        XCTAssertEqual(countedPlan.sourceLayout, .interleavedFile, "the sidecar's count of only pairs outranks the recipe")
        let recipePlan = try await plan(named: recipeOnly)
        XCTAssertEqual(recipePlan.sourceLayout, .interleavedFile, "a scan of the whole file outranks the recipe")
        XCTAssertTrue(recipePlan.layoutReason.contains("recipe VSP2 merges overlapping pairs"), recipePlan.layoutReason)
    }

    /// The preview of a virtual bundle is planned as its bundle, materialized,
    /// with the note the FASTQ subcommands and TaxTriage print.
    func testThePreviewOfAVirtualBundleIsPlannedAsItsBundleWithANote() async throws {
        let preview = fixtures.subsetOfMerge.appendingPathComponent("preview.fastq")
        let notes = NoteRecorder()

        let previewPlan = try await plan(named: preview) { notes.append($0) }

        XCTAssertTrue(previewPlan.wasMaterialized)
        XCTAssertEqual(previewPlan.inputURL.path, fixtures.subsetOfMerge.standardizedFileURL.path)
        XCTAssertEqual(previewPlan.matePairs.count, 1, "the bundle's pair u1, not the preview's one read")
        XCTAssertEqual(previewPlan.composition.pairedFragments, 1)
        XCTAssertEqual(
            notes.values.first,
            "preview.fastq is the preview of the virtual bundle merge-subset.lungfishfastq, not its reads. Reading the bundle instead."
        )
    }

    private func bundle(_ name: String) throws -> URL {
        let url = fixtures.importsURL.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A copy of `file`, and of its sidecar when it has one, in a folder
    /// outside every bundle.
    private func looseCopy(of file: URL, index: Int) throws -> URL {
        let folder = root.appendingPathComponent("loose-copies/\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: copy)
        let sidecar = FASTQMetadataStore.metadataURL(for: file)
        if FileManager.default.fileExists(atPath: sidecar.path) {
            try FileManager.default.copyItem(at: sidecar, to: FASTQMetadataStore.metadataURL(for: copy))
        }
        return copy
    }
}

private final class NoteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ note: String) {
        lock.lock()
        recorded.append(note)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
