// MappingInputResolverTests.swift - Which files a mapper reads and how they pair
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/contracts/READ-PAIRING.md, decision 1. MappingInputResolver is the one
// call the Map Reads window and `lungfish-cli map` make.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class MappingInputResolverTests: XCTestCase {
    private var root: URL!
    private var fixtures: ReadSetFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "mapping-input-resolver")
        fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testCapabilityFollowsTheMapperAndItsPreset() {
        XCTAssertEqual(MappingInputResolver.readPairingCapability(tool: .minimap2, modeID: MappingMode.defaultShortRead.id), .bothInOneRunAsNameInterleavedStream)
        XCTAssertEqual(MappingInputResolver.readPairingCapability(tool: .bwaMem2, modeID: MappingMode.defaultShortRead.id), .bothInOneRunAsNameInterleavedStream)
        XCTAssertEqual(MappingInputResolver.readPairingCapability(tool: .bowtie2, modeID: MappingMode.defaultShortRead.id), .bothInOneRunAsSeparateFiles)
        XCTAssertEqual(MappingInputResolver.readPairingCapability(tool: .bbmap, modeID: MappingMode.bbmapStandard.id), .pairsOrSinglesPerRun)
        // Presets that map every record on their own take no read-set plan.
        for mode in [MappingMode.minimap2MapONT, .minimap2MapHiFi, .minimap2MapPB, .minimap2Asm5, .minimap2Splice] {
            XCTAssertNil(MappingInputResolver.readPairingCapability(tool: .minimap2, modeID: mode.id), mode.id)
        }
        XCTAssertNil(MappingInputResolver.readPairingCapability(tool: .bbmap, modeID: MappingMode.bbmapPacBio.id))
    }

    /// Two loose files pair only when they are named as the mates of one
    /// sample. Two bundles never pair, whatever their names.
    func testOnlyTwoLooseFilesNamedAsMatesPair() {
        func url(_ path: String) -> URL { URL(fileURLWithPath: "/tmp/proj/\(path)") }
        let pair = MappingInputResolver.looseMatePair(in: [url("Sample_R2.fastq.gz"), url("Sample_R1.fastq.gz")])
        XCTAssertEqual(pair?.r1, url("Sample_R1.fastq.gz"), "R1 comes first whatever the order chosen")
        XCTAssertEqual(pair?.r2, url("Sample_R2.fastq.gz"))
        XCTAssertNil(MappingInputResolver.looseMatePair(in: [url("SampleA.fastq.gz"), url("SampleB.fastq.gz")]))
        XCTAssertNil(MappingInputResolver.looseMatePair(in: [url("Sample.fastq.gz")]))
        XCTAssertNil(MappingInputResolver.looseMatePair(in: [url("A.fastq.gz"), url("B.fastq.gz"), url("C.fastq.gz")]))
        XCTAssertNil(MappingInputResolver.looseMatePair(in: [url("Sample_R1.lungfishfastq"), url("Sample_R2.lungfishfastq")]))
        XCTAssertNil(MappingInputResolver.looseMatePair(in: [
            url("Sample_R1.lungfishfastq/Sample_R1.fastq"),
            url("Sample_R2.lungfishfastq/Sample_R2.fastq"),
        ]))
    }

    /// minimap2 `-x sr` and bwa-mem2 `-p` read a merge derivative as one
    /// stream: each R1 record followed by its R2 record, then the merged
    /// reads. The interleave is the plan's step.
    func testStreamMappersReadAMergeDerivativeAsOneNameInterleavedStream() async throws {
        for tool in [MappingTool.minimap2, .bwaMem2] {
            let resolved = try await resolve(fixtures.mergeDerivative, tool: tool)
            let request = resolved.request
            XCTAssertEqual(request.inputFASTQURLs.count, 1)
            XCTAssertEqual(try ReadSetFixtures.readNames(in: request.inputFASTQURLs[0]), ["u1/1", "u1/2", "x1", "x2", "x3"])
            XCTAssertEqual(request.originalInputFASTQURLs, [fixtures.mergeDerivative.standardizedFileURL])
            XCTAssertEqual(request.inputLayout, .mixedMergedAndPairs)
            XCTAssertEqual(request.readLayoutPlan.handling, .asPairs)
            XCTAssertNil(request.readSetLayout)
            XCTAssertFalse(request.pairedEnd)
            let plan = try XCTUnwrap(resolved.readSetPlan)
            XCTAssertEqual(plan.steps.map(\.kind), [.interleaveByName])
            XCTAssertEqual(plan.steps.first?.pairCount, 1)
            XCTAssertEqual(plan.steps.first?.singleReadCount, 3)
            XCTAssertEqual(request.readLayoutPlan.pairedEndDescription, "Yes (pairs; merged reads mapped as single reads)")
        }
    }

    /// A mixed root file is already the stream a stream mapper reads, so it
    /// is handed over in place with no step, as before.
    func testStreamMappersReadAMixedRootInPlace() async throws {
        let resolved = try await resolve(fixtures.mixedRoot, tool: .bwaMem2)
        let file = fixtures.mixedRoot.appendingPathComponent("reads.fastq").standardizedFileURL
        XCTAssertEqual(resolved.request.inputFASTQURLs, [file])
        XCTAssertEqual(resolved.request.originalInputFASTQURLs, [fixtures.mixedRoot.standardizedFileURL])
        XCTAssertEqual(resolved.readSetPlan?.steps, [])
        XCTAssertFalse(resolved.sequenceInputs.didMaterialize)
    }

    /// bowtie2 and BBMap read a mixed root split by name into R1, R2 and
    /// single reads.
    func testSeparateFileMappersReadAMixedRootSplitByName() async throws {
        for tool in [MappingTool.bowtie2, .bbmap] {
            let resolved = try await resolve(fixtures.mixedRoot, tool: tool)
            let sets = try XCTUnwrap(resolved.request.readSetLayout, tool.rawValue)
            XCTAssertEqual(try sets.r1Files.flatMap(ReadSetFixtures.readNames(in:)), ["p1/1", "p2/1"])
            XCTAssertEqual(try sets.r2Files.flatMap(ReadSetFixtures.readNames(in:)), ["p1/2", "p2/2"])
            XCTAssertEqual(try sets.singleReadFiles.flatMap(ReadSetFixtures.readNames(in:)), ["m1", "m2", "m3"])
            XCTAssertEqual(resolved.request.inputFASTQURLs, sets.allFiles)
            XCTAssertEqual(resolved.request.readLayoutPlan.handling, .asPairs)
            XCTAssertEqual(resolved.readSetPlan?.steps.map(\.kind), [.splitByName])
        }
    }

    /// A sample of only single reads or only pairs takes no read-set path,
    /// so its request is the one the mapper took before.
    func testSingleReadsOnlyAndPairsOnlyKeepTheirRequests() async throws {
        for tool in MappingTool.allCases {
            let single = try await resolve(fixtures.singleRoot, tool: tool)
            XCTAssertNil(single.readSetPlan)
            XCTAssertNil(single.request.readSetLayout)
            XCTAssertEqual(single.request.inputLayout, .singleEnd)
            XCTAssertFalse(single.request.pairedEnd)

            let paired = try await resolve(fixtures.pairedDerivative, tool: tool)
            XCTAssertNil(paired.readSetPlan)
            XCTAssertTrue(paired.request.pairedEnd)
            XCTAssertEqual(paired.request.inputLayout, .pairedFiles)

            let interleaved = try await resolve(fixtures.interleavedRoot, tool: tool)
            XCTAssertNil(interleaved.readSetPlan)
            XCTAssertEqual(interleaved.request.inputLayout, .strictlyInterleaved)
        }
    }

    /// A long-read preset maps every record on its own, so a merge
    /// derivative reaches it joined as before.
    func testLongReadPresetsMapAMixedSampleAsSingleReads() async throws {
        let resolved = try await resolve(fixtures.mergeDerivative, tool: .minimap2, modeID: MappingMode.minimap2MapONT.id)
        XCTAssertNil(resolved.readSetPlan)
        XCTAssertEqual(resolved.request.inputFASTQURLs.count, 1)
        XCTAssertEqual(resolved.request.inputLayout, .singleEnd)
        XCTAssertEqual(resolved.layoutResolution.source, .pooledFiles)
    }

    /// Two bundles chosen together are pooled as single reads, never paired
    /// with each other by their names.
    func testTwoBundlesNamedAsMatesArePooled() async throws {
        let imports = root.appendingPathComponent("pooled/Imports", isDirectory: true)
        var bundles: [URL] = []
        for (name, read) in [("sample_R1", "q1/1"), ("sample_R2", "q1/2")] {
            let bundle = imports.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try ReadSetFixtures.fastq([read]).write(to: bundle.appendingPathComponent("\(name).fastq"), atomically: true, encoding: .utf8)
            bundles.append(bundle)
        }
        let resolved = try await MappingInputResolver.resolve(
            request: request(bundles, tool: .bowtie2, modeID: MappingMode.defaultShortRead.id),
            materializer: fixtures.materializer
        )
        XCTAssertFalse(resolved.request.pairedEnd)
        XCTAssertEqual(resolved.request.inputLayout, .singleEnd)
        XCTAssertEqual(resolved.layoutResolution.source, .pooledFiles)
    }

    /// A virtual bundle is materialized once, and the read-set plan and the
    /// files the mapper reads come from that one file.
    func testAVirtualBundleIsMaterializedOnce() async throws {
        let counter = CountingMaterializer(base: fixtures.materializer)
        let resolved = try await MappingInputResolver.resolve(
            request: request([fixtures.subsetOfSingle], tool: .bowtie2, modeID: MappingMode.defaultShortRead.id),
            materializer: counter
        )
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(try ReadSetFixtures.readNames(in: resolved.request.inputFASTQURLs[0]), ["s1", "s3"])
        XCTAssertTrue(resolved.sequenceInputs.didMaterialize)
        XCTAssertNotNil(resolved.request.inputMaterializationStartedAt)
    }

    // MARK: - Helpers

    private func resolve(_ input: URL, tool: MappingTool, modeID: String? = nil) async throws -> MappingResolvedInputs {
        let mode = modeID ?? (tool == .bbmap ? MappingMode.bbmapStandard.id : MappingMode.defaultShortRead.id)
        return try await MappingInputResolver.resolve(
            request: request([input], tool: tool, modeID: mode),
            materializer: fixtures.materializer
        )
    }

    private func request(_ inputs: [URL], tool: MappingTool, modeID: String) -> MappingRunRequest {
        MappingRunRequest(
            tool: tool,
            modeID: modeID,
            inputFASTQURLs: inputs,
            referenceFASTAURL: root.appendingPathComponent("reference.fa"),
            outputDirectory: root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true),
            sampleName: "sample",
            threads: 1
        )
    }
}

/// Counts materializations.
private final class CountingMaterializer: CLISequenceInputMaterializing, @unchecked Sendable {
    let base: ReadSetFixtures.StubMaterializer
    private let lock = NSLock()
    private var calls = 0

    init(base: ReadSetFixtures.StubMaterializer) {
        self.base = base
    }

    var count: Int { lock.withLock { calls } }

    func materialize(bundleURL: URL, tempDirectory: URL, progress: (@Sendable (String) -> Void)?) async throws -> URL {
        lock.withLock { calls += 1 }
        return try await base.materialize(bundleURL: bundleURL, tempDirectory: tempDirectory, progress: progress)
    }
}
