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

    /// A sample of pairs and single reads records the read-set plan once, in
    /// the run's resolved defaults, the one home of the plan (E13): the
    /// capability, the fragment counts by kind and the number of runs
    /// (READ-PAIRING.md, Provenance). BBMap maps such a sample in two runs and
    /// still holds one plan, and no mapper step holds a copy. A sample of only
    /// single reads records nothing new.
    ///
    /// The typed `mapping-provenance.json` record holds the plan once too, at
    /// its own level. Every reader that rebuilds a record from it has no other
    /// copy, and `bam adopt-mapping` and viewer publication save it again, so
    /// an adopted bundle holds nothing else of the run.
    func testRunRecordsTheReadSetPlanOnceInItsOneHome() async throws {
        let streamDirectory = root.appendingPathComponent("plan-stream", isDirectory: true)
        try await map(fixtures.mergeDerivative, tool: .minimap2, outputDirectory: streamDirectory)
        let bbmapDirectory = root.appendingPathComponent("plan-bbmap", isDirectory: true)
        try await map(fixtures.mergeDerivative, tool: .bbmap, outputDirectory: bbmapDirectory)
        let singleDirectory = root.appendingPathComponent("plan-single", isDirectory: true)
        try await map(fixtures.singleRoot, tool: .minimap2, outputDirectory: singleDirectory)
        _ = try standIn.takeCalls()

        let stream = try Self.recordedEnvelope(in: streamDirectory)
        XCTAssertEqual(stream.steps.filter { $0.toolName == "minimap2" }.count, 1, "\(stream.steps.map(\.toolName))")
        let streamPlan = try XCTUnwrap(stream.readSetPlan, "the run records the read-set plan")
        XCTAssertEqual(streamPlan.place, .resolvedDefaults, "the plan's one home (E13)")
        XCTAssertEqual(streamPlan.fields["capability"], .string("both_in_one_run/name_interleaved_stream"))
        XCTAssertEqual(streamPlan.fields["pairedFragments"], .integer(1))
        XCTAssertEqual(streamPlan.fields["mergedReads"], .integer(3))
        XCTAssertEqual(streamPlan.fields["runs"], .integer(1))
        Self.assertNoSecondCopy(of: stream, in: streamDirectory)
        try Self.assertTypedRecordHoldsThePlan(streamPlan, in: streamDirectory)

        let bbmap = try Self.recordedEnvelope(in: bbmapDirectory)
        XCTAssertEqual(bbmap.steps.filter { $0.toolName == "bbmap.sh" }.count, 2, "\(bbmap.steps.map(\.toolName))")
        let bbmapPlan = try XCTUnwrap(bbmap.readSetPlan, "the run records the read-set plan")
        XCTAssertEqual(bbmapPlan.place, .resolvedDefaults, "the plan's one home (E13)")
        XCTAssertEqual(bbmapPlan.fields["capability"], .string("pairs_or_singles_per_run"))
        XCTAssertEqual(bbmapPlan.fields["pairedFragments"], .integer(1))
        XCTAssertEqual(bbmapPlan.fields["mergedReads"], .integer(3))
        XCTAssertEqual(bbmapPlan.fields["runs"], .integer(2))
        Self.assertNoSecondCopy(of: bbmap, in: bbmapDirectory)
        try Self.assertTypedRecordHoldsThePlan(bbmapPlan, in: bbmapDirectory)
        try assertThePlanSurvivesAdoption(of: bbmapPlan, from: bbmapDirectory)

        let single = try Self.recordedEnvelope(in: singleDirectory)
        XCTAssertNil(single.readSetPlan, "a sample of only single reads records nothing new")
        XCTAssertEqual(single.options.resolvedDefaults, [:], "a run without a plan adds nothing to the resolved defaults")
        Self.assertNoSecondCopy(of: single, in: singleDirectory)

        // The typed record encodes the plan only when there is one, so a run
        // without a plan writes the sidecar it always wrote.
        let singleSidecar = try Self.rawSidecar(in: singleDirectory)
        XCTAssertNotNil(singleSidecar["sampleName"], "the sidecar was read")
        XCTAssertNil(singleSidecar[RecordedReadSetPlan.key], "a run without a plan writes no readSetPlan key")
        XCTAssertNil(MappingProvenance.load(from: singleDirectory)?.readSetPlan, "the typed record holds no plan")
        let singleReading = ProvenanceRecorder.findProvenanceReading(
            for: singleDirectory.appendingPathComponent(MappingProvenance.filename)
        )
        XCTAssertNotNil(singleReading, "the finder reads the sidecar")
        XCTAssertNil(singleReading?.reading.envelope.readSetPlan, "the sidecar reads with no plan")
    }

    private static func recordedEnvelope(in directory: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: directory), "the run wrote its record")
    }

    /// The plan sits in the resolved defaults and nowhere else: not in the
    /// explicit options, not in the parameters of the run nested in the record,
    /// not in a step of the record, and not in a step of the
    /// `mapping-provenance.json` sidecar.
    private static func assertNoSecondCopy(
        of envelope: ProvenanceEnvelope,
        in directory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let key = RecordedReadSetPlan.key
        XCTAssertNil(envelope.options.explicit[key], "no copy in the explicit options", file: file, line: line)
        XCTAssertNil(envelope.legacyRun?.parameters[key], "no copy in the parameters of the nested run", file: file, line: line)
        XCTAssertEqual(
            envelope.steps.filter { $0.resolvedOptions[key] != nil }.map(\.toolName), [],
            "no step of the record holds a copy", file: file, line: line
        )
        let sidecar = MappingProvenance.load(from: directory)
        XCTAssertNotNil(sidecar, "the sidecar was written", file: file, line: line)
        XCTAssertEqual(
            (sidecar?.steps ?? []).filter { $0.resolvedOptions?[key] != nil }.map(\.toolName), [],
            "no step of the sidecar holds a copy", file: file, line: line
        )
    }

    /// The typed record holds the plan at its own level. A script reads one
    /// `readSetPlan` key in the file, and the Inspector, `lungfish provenance`
    /// and a lineage export, which rebuild a record from the file, find the
    /// plan in the one home.
    private static func assertTypedRecordHoldsThePlan(
        _ plan: RecordedReadSetPlan,
        in directory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            MappingProvenance.load(from: directory)?.readSetPlan, .dictionary(plan.fields),
            "the typed record holds the plan", file: file, line: line
        )
        assertSidecarReading(in: directory, holds: plan, file: file, line: line)
        let sidecar = try rawSidecar(in: directory, file: file, line: line)
        XCTAssertNotNil(sidecar[RecordedReadSetPlan.key], "the sidecar file holds the plan", file: file, line: line)
        XCTAssertEqual(sidecar["schemaVersion"] as? Int, 3, "the plan does not change the sidecar's schema version", file: file, line: line)
    }

    /// What the finder makes of `mapping-provenance.json` itself, the typed
    /// record rebuilt as an envelope, holds the plan in the one home.
    private static func assertSidecarReading(
        in directory: URL,
        holds plan: RecordedReadSetPlan,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reading = ProvenanceRecorder.findProvenanceReading(
            for: directory.appendingPathComponent(MappingProvenance.filename)
        )
        let read = reading?.reading.envelope.readSetPlan
        XCTAssertEqual(read?.place, .resolvedDefaults, "the sidecar reads with the plan in the one home", file: file, line: line)
        XCTAssertEqual(read?.fields, plan.fields, "the sidecar reads with the same plan", file: file, line: line)
    }

    /// The sidecar as a script reads it, a JSON object.
    private static func rawSidecar(
        in directory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(MappingProvenance.filename))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "the sidecar is a JSON object", file: file, line: line
        )
    }

    /// `bam adopt-mapping` loads the sidecar, points it at the bundle and saves
    /// it again, and viewer publication does the same with the source reference
    /// bundle too. The saved sidecar is all an adopted bundle holds of the run,
    /// so it keeps the plan.
    private func assertThePlanSurvivesAdoption(
        of plan: RecordedReadSetPlan,
        from directory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let loaded = try XCTUnwrap(MappingProvenance.load(from: directory), "the sidecar loads", file: file, line: line)
        let adoptedDirectory = root.appendingPathComponent("plan-adopted", isDirectory: true)
        try loaded
            .withViewerBundleURL(root.appendingPathComponent("viewer.lungfishref", isDirectory: true))
            .withSourceReferenceBundleURL(root.appendingPathComponent("source.lungfishref", isDirectory: true))
            .save(to: adoptedDirectory)
        XCTAssertEqual(
            MappingProvenance.load(from: adoptedDirectory)?.readSetPlan, .dictionary(plan.fields),
            "the saved sidecar loads with the plan", file: file, line: line
        )
        Self.assertSidecarReading(in: adoptedDirectory, holds: plan, file: file, line: line)
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
        let resolved = try await MappingInputResolver.resolve(
            request: MappingRunRequest(
                tool: tool,
                modeID: modeID,
                inputFASTQURLs: [input],
                referenceFASTAURL: standIn.referenceURL,
                outputDirectory: outputDirectory,
                sampleName: input.deletingPathExtension().lastPathComponent,
                threads: 2,
                compatibilityReadClassOverride: .illuminaShortReads
            ),
            materializer: fixtures.materializer
        )
        _ = try await standIn.pipeline.run(
            request: resolved.request,
            inputLayoutReason: resolved.layoutResolution.reason,
            readSetPlan: resolved.readSetPlan
        )
    }
}
