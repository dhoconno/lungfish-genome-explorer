// MapReadSetStandInTests.swift - What each mapper is handed for every bundle read layout
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/contracts/READ-PAIRING.md, owner decision 1. Pairs that were not
// merged reach a mapper as pairs, and merged and orphan reads as single
// reads. Each test resolves one ReadSetFixtures bundle the way
// `lungfish-cli map` does, runs ManagedMappingPipeline with stand-in tools
// and checks the flags that decide pairing and the reads of every file each
// mapper call was handed. A sample of only single reads or only pairs keeps
// the command it had before the read-set contract.

import Foundation
import XCTest
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class MapReadSetStandInTests: XCTestCase {
    private var root: URL!
    private var fixtures: ReadSetFixtures!
    private var standIn: MapReadSetStandIn!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "map-read-set")
        fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        standIn = try MapReadSetStandIn.make(in: root.appendingPathComponent("tools", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Single reads only and pairs only keep their commands

    func testSingleEndRootIsUnchanged() async throws {
        try await assertInputs(fixtures.singleRoot, [
            .minimap2: ["[s1,s2,s3]"],
            .bwaMem2: ["[s1,s2,s3]"],
            .bowtie2: ["-U [s1,s2,s3]"],
            .bbmap: ["in=[s1,s2,s3] interleaved=f"],
        ])
    }

    func testInterleavedRootIsUnchanged() async throws {
        let reads = "[i1/1,i1/2,i2/1,i2/2]"
        try await assertInputs(fixtures.interleavedRoot, [
            .minimap2: [reads],
            .bwaMem2: ["-p \(reads)"],
            .bowtie2: ["--interleaved \(reads)"],
            .bbmap: ["in=\(reads) interleaved=t"],
        ])
    }

    func testChunkedRootIsConcatenatedAsBefore() async throws {
        let reads = "[c1,c2,c3]"
        try await assertInputs(fixtures.chunkedRoot, [
            .minimap2: [reads],
            .bwaMem2: [reads],
            .bowtie2: ["-U \(reads)"],
            .bbmap: ["in=\(reads) interleaved=f"],
        ])
    }

    func testPairedDerivativeIsUnchanged() async throws {
        try await assertInputs(fixtures.pairedDerivative, [
            .minimap2: ["[p1/1,p2/1] [p1/2,p2/2]"],
            .bwaMem2: ["[p1/1,p2/1] [p1/2,p2/2]"],
            .bowtie2: ["-1 [p1/1,p2/1] -2 [p1/2,p2/2]"],
            .bbmap: ["in=[p1/1,p2/1] in2=[p1/2,p2/2]"],
        ])
    }

    func testVirtualSubsetOfSingleReadsIsUnchanged() async throws {
        try await assertInputs(fixtures.subsetOfSingle, [
            .minimap2: ["[s1,s3]"],
            .bwaMem2: ["[s1,s3]"],
            .bowtie2: ["-U [s1,s3]"],
            .bbmap: ["in=[s1,s3] interleaved=f"],
        ])
    }

    // MARK: - Pairs and single reads in one sample (decision 1)

    /// L3: the mixed root file is the stream minimap2 and bwa-mem2 take, used
    /// in place. bowtie2 gets it split by name and BBMap maps each part.
    /// Before: bowtie2 `-U` and BBMap `interleaved=f`, every read single.
    func testMixedRootMapsItsPairsAsPairs() async throws {
        let stream = "[m1,m2,m3,p1/1,p1/2,p2/1,p2/2]"
        try await assertInputs(fixtures.mixedRoot, [
            .minimap2: [stream],
            .bwaMem2: ["-p \(stream)"],
            .bowtie2: ["-1 [p1/1,p2/1] -2 [p1/2,p2/2] -U [m1,m2,m3]"],
            .bbmap: ["in=[p1/1,p2/1] in2=[p1/2,p2/2]", "in=[m1,m2,m3] interleaved=f"],
        ])
    }

    /// L5c: before, the merged, R1 and R2 files were joined end to end and
    /// mapped as single reads by every mapper.
    func testMergeDerivativeMapsItsUnmergedPairsAsPairs() async throws {
        try await assertInputs(fixtures.mergeDerivative, [
            .minimap2: ["[u1/1,u1/2,x1,x2,x3]"],
            .bwaMem2: ["-p [u1/1,u1/2,x1,x2,x3]"],
            .bowtie2: ["-1 [u1/1] -2 [u1/2] -U [x1,x2,x3]"],
            .bbmap: ["in=[u1/1] in2=[u1/2]", "in=[x1,x2,x3] interleaved=f"],
        ])
    }

    /// L5d: the orphans go as single reads.
    func testRepairDerivativeMapsOrphansAsSingleReads() async throws {
        try await assertInputs(fixtures.repairDerivative, [
            .minimap2: ["[r1/1,r1/2,r2/1,r2/2,o1]"],
            .bwaMem2: ["-p [r1/1,r1/2,r2/1,r2/2,o1]"],
            .bowtie2: ["-1 [r1/1,r2/1] -2 [r1/2,r2/2] -U [o1]"],
            .bbmap: ["in=[r1/1,r2/1] in2=[r1/2,r2/2]", "in=[o1] interleaved=f"],
        ])
    }

    /// L6 of a merge derivative: the materialization holds mates by name,
    /// then the merged read.
    func testVirtualSubsetOfMergeDerivativeMapsItsPairAsAPair() async throws {
        try await assertInputs(fixtures.subsetOfMerge, [
            .minimap2: ["[u1/1,u1/2,x1]"],
            .bwaMem2: ["-p [u1/1,u1/2,x1]"],
            .bowtie2: ["-1 [u1/1] -2 [u1/2] -U [x1]"],
            .bbmap: ["in=[u1/1] in2=[u1/2]", "in=[x1] interleaved=f"],
        ])
    }

    /// BBMap maps pairs and single reads in two runs. Each run's output is
    /// sorted, `samtools merge -c -p` joins them, and the merge is sorted,
    /// indexed and summarized like any other run.
    func testBBMapRunsTwiceAndMergesTheSortedRuns() async throws {
        let outputDirectory = root.appendingPathComponent("bbmap-out", isDirectory: true)
        try await map(fixtures.mergeDerivative, tool: .bbmap, outputDirectory: outputDirectory)
        let calls = try standIn.takeCalls()
        let samtools = calls.filter { $0.tool == "samtools" }
        let merges = samtools.filter { $0.argv.first == "merge" }
        XCTAssertEqual(merges.count, 1, "\(samtools.map(\.argv))")
        let merge = try XCTUnwrap(merges.first)
        XCTAssertTrue(merge.argv.contains("-c") && merge.argv.contains("-p"), "\(merge.argv)")
        let bbmapIndex = try XCTUnwrap(calls.lastIndex { $0.tool == "bbmap.sh" })
        let mergeIndex = try XCTUnwrap(calls.firstIndex { $0.tool == "samtools" && $0.argv.first == "merge" })
        XCTAssertLessThan(bbmapIndex, mergeIndex)
        let sortsBeforeMerge = calls[..<mergeIndex].filter { $0.tool == "samtools" && $0.argv.first == "sort" }
        XCTAssertEqual(sortsBeforeMerge.count, 2, "each run is sorted before the merge")
        XCTAssertTrue(
            calls[mergeIndex...].contains { $0.tool == "samtools" && $0.argv.first == "sort" },
            "the merge is sorted"
        )
        let bbmapReadGroups = calls.filter { $0.tool == "bbmap.sh" }.map { $0.argv.filter { $0.hasPrefix("rg") } }
        XCTAssertEqual(Set(bbmapReadGroups.map { $0.joined(separator: " ") }).count, 1, "both runs share one read group")

        let provenance = try XCTUnwrap(MappingProvenance.load(from: outputDirectory))
        let toolNames = provenance.steps.map(\.toolName)
        XCTAssertEqual(toolNames.filter { $0 == "bbmap.sh" }.count, 2, "\(toolNames)")
        XCTAssertTrue(provenance.steps.contains { $0.command.contains("merge") }, "\(toolNames)")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
            .filter { $0.hasSuffix(".bam") || $0.hasSuffix(".sam") }
        XCTAssertEqual(leftovers, ["merge.sorted.bam"], "the intermediate BAMs are removed")
    }

    // MARK: - Chunked roots are paired by name only for a short-read platform (D9)

    /// A Nanopore import whose two chunks are named `x_1` and `x_2`, and a
    /// chunked root that records no known platform, are pooled as single
    /// reads like any chunked root. Before, the two chunks were handed over
    /// as R1 and R2 of unequal length, so the mappers mis-paired them.
    func testChunksNamedLikeMatesArePooledUnlessAShortReadPlatformIsRecorded() async throws {
        try await assertInputs(fixtures.nanoporeChunkedRoot, [
            .minimap2: ["[o-a,o-b,o-c]"],
            .bwaMem2: ["[o-a,o-b,o-c]"],
            .bowtie2: ["-U [o-a,o-b,o-c]"],
            .bbmap: ["in=[o-a,o-b,o-c] interleaved=f"],
        ])
        try await assertInputs(fixtures.unknownPlatformChunkedRoot, [
            .minimap2: ["[v1,v2]"],
            .bwaMem2: ["[v1,v2]"],
            .bowtie2: ["-U [v1,v2]"],
            .bbmap: ["in=[v1,v2] interleaved=f"],
        ])
        // Illumina chunks named as R1 and R2 stay one mate pair.
        try await assertInputs(fixtures.namedPairChunkedRoot, [
            .minimap2: ["[q1/1] [q1/2]"],
            .bwaMem2: ["[q1/1] [q1/2]"],
            .bowtie2: ["-1 [q1/1] -2 [q1/2]"],
            .bbmap: ["in=[q1/1] in2=[q1/2]"],
        ])
    }

    // MARK: - Provenance records the files written for the mapper

    /// The stream a stream mapper reads for a merge derivative is recorded
    /// as an interleave step with its record counts.
    func testInterleaveOfAMergeDerivativeIsAProvenanceStep() async throws {
        let outputDirectory = root.appendingPathComponent("interleave-out", isDirectory: true)
        try await map(fixtures.mergeDerivative, tool: .minimap2, outputDirectory: outputDirectory)
        _ = try standIn.takeCalls()
        let provenance = try XCTUnwrap(MappingProvenance.load(from: outputDirectory))
        let step = try XCTUnwrap(
            provenance.steps.first { $0.toolName == "Lungfish Read-Set Interleave" },
            "\(provenance.steps.map(\.toolName))"
        )
        XCTAssertEqual(step.resolvedOptions?["pairs"], .integer(1))
        XCTAssertEqual(step.resolvedOptions?["singleReads"], .integer(3))
        XCTAssertEqual(
            step.outputs.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path },
            provenance.inputFASTQPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            "the mapper read the interleaved stream"
        )
    }

    /// A split of a virtual bundle records the materialization that wrote
    /// the split's input, then the split, never a materialization of the
    /// split's outputs.
    func testSplitOfAVirtualBundleRecordsItsMaterializationThenTheSplit() async throws {
        let outputDirectory = root.appendingPathComponent("split-out", isDirectory: true)
        try await map(fixtures.subsetOfMerge, tool: .bowtie2, outputDirectory: outputDirectory)
        _ = try standIn.takeCalls()
        let provenance = try XCTUnwrap(MappingProvenance.load(from: outputDirectory))
        let names = provenance.steps.map(\.toolName)
        let materialization = try XCTUnwrap(
            provenance.steps.first { $0.toolName == CLISequenceInputMaterialization.materializationToolName },
            "\(names)"
        )
        let split = try XCTUnwrap(provenance.steps.first { $0.toolName == "Lungfish Read-Set Split" }, "\(names)")
        XCTAssertEqual(materialization.outputs.map(\.path), split.inputs.map(\.path), "the split reads the materialized file")
        XCTAssertEqual(split.outputs.count, 3)
        XCTAssertLessThan(try XCTUnwrap(names.firstIndex(of: materialization.toolName)), try XCTUnwrap(names.firstIndex(of: split.toolName)))
    }

    // MARK: - Helpers

    /// Maps `bundle` with every mapper and checks what each was handed, in
    /// one comparison of the whole table, so every mismatch is reported.
    private func assertInputs(
        _ bundle: URL,
        _ expected: [MappingTool: [String]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        var actual: [String: [String]] = [:]
        for tool in MappingTool.allCases {
            let outputDirectory = root.appendingPathComponent("\(bundle.deletingPathExtension().lastPathComponent)-\(tool.rawValue)", isDirectory: true)
            try await map(bundle, tool: tool, outputDirectory: outputDirectory)
            actual[tool.rawValue] = try MapReadSetStandIn.mapperInputs(standIn.takeCalls())
        }
        let wanted = Dictionary(uniqueKeysWithValues: expected.map { ($0.key.rawValue, $0.value) })
        XCTAssertEqual(actual, wanted, "mapper inputs for \(bundle.lastPathComponent)", file: file, line: line)
    }

    /// Resolves `input` the way `lungfish-cli map` does and runs the pipeline.
    private func map(_ input: URL, tool: MappingTool, outputDirectory: URL) async throws {
        let modeID = tool == .bbmap ? MappingMode.bbmapStandard.id : MappingMode.defaultShortRead.id
        let resolvedInputs = try await MapCommand.resolveExecutionInputs(
            for: [input],
            tempDirectory: MappingResultLayoutService.inputMaterializationDirectory(in: outputDirectory),
            materializer: fixtures.materializer
        )
        let pairedEnd = MapCommand.effectivePairedEnd(flag: false, resolved: resolvedInputs)
        let layout = MapCommand.layoutResolution(for: resolvedInputs, pairedEnd: pairedEnd, explicit: nil)
        let request = MappingRunRequest(
            tool: tool,
            modeID: modeID,
            inputFASTQURLs: resolvedInputs.executionInputURLs,
            referenceFASTAURL: standIn.referenceURL,
            outputDirectory: outputDirectory,
            sampleName: input.deletingPathExtension().lastPathComponent,
            pairedEnd: pairedEnd,
            threads: 2,
            compatibilityReadClassOverride: .illuminaShortReads,
            inputLayout: layout.layout
        ).withInputLineage(resolvedInputs)
        _ = try await standIn.pipeline.run(request: request, inputLayoutReason: layout.reason)
    }
}
