// AssemblyReadSetResolutionTests.swift - Which samples an assembler takes as pairs plus single reads, and which keep their old resolution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `AssemblyReadSetResolution.resolve` is the one place `lungfish-cli assemble`
// and the app's Reassemble resolve their inputs (owner decision 1 of
// 2026-10-03, docs/contracts/READ-PAIRING.md). A sample that holds pairs
// and single reads comes out as an R1 file, an R2 file and single-read files
// with roles. Every other sample resolves as `resolveForAssembly` resolves it.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class AssemblyReadSetResolutionTests: XCTestCase {
    private var root: URL!
    private var fixtures: ReadSetFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "assembly-read-set-resolution")
        fixtures = try ReadSetFixtures(in: root)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Pairs and single reads

    func testASampleOfPairsAndSingleReadsResolvesToAPairAndFilesWithRoles() async throws {
        let cases: [(shape: String, bundle: URL, reads: [[String]], roles: [AssemblyInputRole])] = [
            ("L3 root", fixtures.mixedRoot, [["p1/1", "p2/1"], ["p1/2", "p2/2"], ["m1", "m2", "m3"]], [.mateR1, .mateR2, .merged]),
            ("L5c merge", fixtures.mergeDerivative, [["u1/1"], ["u1/2"], ["x1", "x2", "x3"]], [.mateR1, .mateR2, .merged]),
            ("L5d repair", fixtures.repairDerivative, [["r1/1", "r2/1"], ["r1/2", "r2/2"], ["o1"]], [.mateR1, .mateR2, .single]),
            ("L6 merge subset", fixtures.subsetOfMerge, [["u1/1"], ["u1/2"], ["x1"]], [.mateR1, .mateR2, .merged]),
            ("L5a merge output", fixtures.fullMergeOutput, [["p1/1"], ["p1/2"], ["m1", "m2"]], [.mateR1, .mateR2, .merged]),
        ]
        for testCase in cases {
            let resolved = try await resolve([testCase.bundle], tool: .spades)
            XCTAssertEqual(resolved.inputRoles, testCase.roles, testCase.shape)
            XCTAssertEqual(try reads(resolved), testCase.reads, testCase.shape)
            XCTAssertEqual(resolved.inputs.originalInputURLs, Array(repeating: testCase.bundle.standardizedFileURL, count: 3), testCase.shape)
            XCTAssertFalse(resolved.inputs.resolvedAsMatePair, testCase.shape)
            XCTAssertNotNil(resolved.plan, testCase.shape)
        }
    }

    /// Reads whose role the sidecar cannot tell, merged or orphan, are single
    /// reads. Only reads known to be merged are SPAdes `--merged` reads.
    func testReadsThatMayBeMergedOrOrphansAreSingleReads() async throws {
        let bundle = fixtures.importsURL.appendingPathComponent("merged-and-orphans.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let file = bundle.appendingPathComponent("reads.fastq")
        try ReadSetFixtures.fastq(["m1", "o1", "p1/1", "p1/2"]).write(to: file, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(
                ingestion: IngestionMetadata(pairingMode: .interleaved, pairingSource: .detected),
                readClassification: ReadClassification(files: [
                    .init(filename: "reads.fastq", role: .merged, readCount: 1),
                    .init(filename: "reads.fastq", role: .unpaired, readCount: 1),
                    .init(filename: "reads.fastq", role: .pairedR1, readCount: 1),
                    .init(filename: "reads.fastq", role: .pairedR2, readCount: 1),
                ])
            ),
            for: file
        )
        let resolved = try await resolve([bundle], tool: .spades)
        XCTAssertEqual(resolved.inputRoles, [.mateR1, .mateR2, .single])
        XCTAssertEqual(try reads(resolved), [["p1/1"], ["p1/2"], ["m1", "o1"]])
    }

    /// A merge derivative given as the R1 and R2 files a batch launch names is
    /// the same sample once.
    func testTheFilesOfOneMixedBundleGivenSeparatelyAreThatSampleOnce() async throws {
        let files = ["merged.fastq", "unmerged_R1.fastq", "unmerged_R2.fastq"].map {
            fixtures.mergeDerivative.appendingPathComponent($0)
        }
        let resolved = try await resolve(files, tool: .megahit)
        XCTAssertEqual(resolved.inputRoles, [.mateR1, .mateR2, .merged])
        XCTAssertEqual(try reads(resolved), [["u1/1"], ["u1/2"], ["x1", "x2", "x3"]])
    }

    /// A virtual bundle is materialized once for the plan and the plan's
    /// split reads that file. A virtual bundle that does not hold pairs and
    /// single reads is materialized once as well.
    func testAVirtualBundleIsMaterializedOnce() async throws {
        for bundle in [fixtures.subsetOfMerge, fixtures.subsetOfSingle, fixtures.subsetOfRepair] {
            let counting = CountingMaterializer(base: fixtures.materializer)
            _ = try await resolve([bundle], tool: .spades, materializer: counting)
            let calls = await counting.calls
            XCTAssertEqual(calls, 1, bundle.lastPathComponent)
        }
    }

    func testTheResolutionRecordsTheSplitAndTheMaterializationAsProvenanceSteps() async throws {
        let split = try await resolve([fixtures.mixedRoot], tool: .spades)
        let splitSteps = try split.provenanceSteps(workflowVersion: "test")
        XCTAssertEqual(splitSteps.map(\.toolName), ["Lungfish Read-Set Split"])
        XCTAssertEqual(splitSteps.first?.resolvedOptions["pairs"], .integer(2))
        XCTAssertEqual(splitSteps.first?.resolvedOptions["singleReads"], .integer(3))
        XCTAssertEqual(splitSteps.first?.outputs.count, 3)
        XCTAssertNotNil(split.provenanceParameters["readSetPlan"])

        let virtual = try await resolve([fixtures.subsetOfMerge], tool: .spades)
        let virtualSteps = try virtual.provenanceSteps(workflowVersion: "test")
        XCTAssertEqual(virtualSteps.map(\.toolName), [CLISequenceInputMaterialization.materializationToolName, "Lungfish Read-Set Split"])
        XCTAssertEqual(virtualSteps[0].outputs.map(\.path), virtualSteps[1].inputs.map(\.path), "the split reads the materialized file")

        // Separate role files are the bundle's own files, so nothing is written.
        let roles = try await resolve([fixtures.mergeDerivative], tool: .spades)
        XCTAssertEqual(try roles.provenanceSteps(workflowVersion: "test"), [])
        XCTAssertNotNil(roles.provenanceParameters["readSetPlan"])
    }

    // MARK: - Unchanged

    /// A sample of only single reads or only pairs resolves to the files
    /// `resolveForAssembly` gives it, with no roles and no plan.
    func testASampleOfOnlySingleReadsOrOnlyPairsResolvesAsItAlwaysDid() async throws {
        let bundles = [
            fixtures.singleRoot, fixtures.interleavedRoot, fixtures.chunkedRoot, fixtures.fullDerivative,
            fixtures.fullUnlabelled, fixtures.pairedDerivative, fixtures.fastaDerivative,
            fixtures.subsetOfSingle, fixtures.subsetOfInterleaved, fixtures.subsetOfRepair,
        ]
        for tool in [AssemblyTool.spades, .megahit, .skesa, .flye, .hifiasm] {
            for bundle in bundles {
                let label = "\(tool.rawValue) \(bundle.lastPathComponent)"
                let legacy = try await ResolvedSequenceInputs.resolveForAssembly(
                    inputURLs: [bundle],
                    materializationDirectory: root.appendingPathComponent("legacy-\(UUID().uuidString)", isDirectory: true),
                    materializer: fixtures.materializer
                )
                let resolved = try await resolve([bundle], tool: tool)
                XCTAssertNil(resolved.inputRoles, label)
                XCTAssertNil(resolved.plan, label)
                XCTAssertEqual(resolved.inputs.originalInputURLs, legacy.originalInputURLs, label)
                XCTAssertEqual(resolved.inputs.resolvedAsMatePair, legacy.resolvedAsMatePair, label)
                XCTAssertEqual(
                    try resolved.inputs.executionInputURLs.map(ReadSetFixtures.readNames(in:)),
                    try legacy.executionInputURLs.map(ReadSetFixtures.readNames(in:)),
                    label
                )
                XCTAssertEqual(try resolved.provenanceSteps(workflowVersion: "test"), [], label)
                XCTAssertEqual(resolved.provenanceParameters, [:], label)
            }
        }
    }

    /// Flye and hifiasm take every record as a single read, and a flag or
    /// several samples keep the resolution they had.
    func testLongReadAssemblersTheFlagAndSeveralSamplesKeepTheOldResolution() async throws {
        for tool in [AssemblyTool.flye, .hifiasm] {
            let resolved = try await resolve([fixtures.mergeDerivative], tool: tool)
            XCTAssertNil(resolved.inputRoles, tool.rawValue)
            XCTAssertEqual(try reads(resolved), [["x1", "x2", "x3", "u1/1", "u1/2"]], "\(tool.rawValue) reads the joined files")
        }
        let flagged = try await resolve(
            [fixtures.pairedDerivative.appendingPathComponent("sample_R1.fastq"), fixtures.pairedDerivative.appendingPathComponent("sample_R2.fastq")],
            tool: .spades,
            pairedEnd: true
        )
        XCTAssertNil(flagged.inputRoles)
        XCTAssertTrue(flagged.inputs.resolvedAsMatePair)

        let two = try await resolve([fixtures.mergeDerivative, fixtures.singleRoot], tool: .spades)
        XCTAssertNil(two.inputRoles, "two samples are pooled as they were")
    }

    // MARK: - An explicit layout

    /// `--read-layout` states the layout of one file. It overrides the
    /// layout of a loose file and of a bundle's one file, and it is refused
    /// for a bundle whose pairs and single reads are in several files.
    func testAnExplicitLayoutOverridesOneFileAndIsRefusedForSeveralFiles() async throws {
        // The L3 root bundle has one file.
        for layout in [FASTQInputLayout.singleEnd, .strictlyInterleaved] {
            let stated = try await resolve([fixtures.mixedRoot], tool: .spades, explicitLayout: layout)
            XCTAssertNil(stated.inputRoles, "\(layout) is read as stated")
            XCTAssertEqual(try reads(stated), [["m1", "m2", "m3", "p1/1", "p1/2", "p2/1", "p2/2"]])
        }
        let mixed = try await resolve([fixtures.mixedRoot], tool: .spades, explicitLayout: .mixedMergedAndPairs)
        XCTAssertEqual(mixed.inputRoles, [.mateR1, .mateR2, .merged])

        // The merge derivative has a file per role.
        for layout in FASTQInputLayout.allCases {
            do {
                _ = try await resolve([fixtures.mergeDerivative], tool: .spades, explicitLayout: layout)
                XCTFail("\(layout) must be refused for a bundle with a file per role")
            } catch let error as AssemblyReadSetResolutionError {
                XCTAssertEqual(
                    error,
                    .readLayoutNamesABundleOfSeveralFiles(bundleName: fixtures.mergeDerivative.lastPathComponent)
                )
            }
        }

        // A loose file takes a stated layout, and reads as pairs plus single reads without one.
        let loose = root.appendingPathComponent("loose.fastq")
        try ReadSetFixtures.fastq(["m1", "p1/1", "p1/2"]).write(to: loose, atomically: true, encoding: .utf8)
        let auto = try await resolve([loose], tool: .spades)
        XCTAssertEqual(auto.inputRoles, [.mateR1, .mateR2, .single])
        XCTAssertEqual(try reads(auto), [["p1/1"], ["p1/2"], ["m1"]])
        let single = try await resolve([loose], tool: .spades, explicitLayout: .singleEnd)
        XCTAssertNil(single.inputRoles)
        XCTAssertEqual(try reads(single), [["m1", "p1/1", "p1/2"]])
    }

    // MARK: - Nothing is assembled on part of a sample

    func testAMissingRoleFileStopsTheRunInsteadOfAssemblingTheRest() async throws {
        let unmergedR2 = fixtures.mergeDerivative.appendingPathComponent("unmerged_R2.fastq")
        try FileManager.default.removeItem(at: unmergedR2)
        do {
            _ = try await resolve([fixtures.mergeDerivative], tool: .spades)
            XCTFail("a missing file of the sample must stop the run")
        } catch let error as ReadSetResolverError {
            guard case .missingFile(_, let filePath) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(filePath.hasSuffix("unmerged_R2.fastq"), filePath)
        }
    }

    func testASampleWithTwoPairsOfMateFilesIsRefused() async throws {
        let bundle = fixtures.importsURL.appendingPathComponent("two-pairs.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for (name, names) in [("a_R1.fastq", ["a/1"]), ("a_R2.fastq", ["a/2"]), ("b_R1.fastq", ["b/1"]), ("b_R2.fastq", ["b/2"]), ("single.fastq", ["s1"])] {
            try ReadSetFixtures.fastq(names).write(to: bundle.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let classification = ReadClassification(files: [
            .init(filename: "a_R1.fastq", role: .pairedR1, readCount: 1),
            .init(filename: "a_R2.fastq", role: .pairedR2, readCount: 1),
            .init(filename: "b_R1.fastq", role: .pairedR1, readCount: 1),
            .init(filename: "b_R2.fastq", role: .pairedR2, readCount: 1),
            .init(filename: "single.fastq", role: .unpaired, readCount: 1),
        ])
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "two-pairs",
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: "single.fastq",
                payload: .fullMixed(classification),
                lineage: [FASTQDerivativeOperation(kind: .pairedEndRepair)],
                operation: FASTQDerivativeOperation(kind: .pairedEndRepair),
                cachedStatistics: .placeholder(readCount: 2, baseCount: 20),
                pairingMode: .pairedEnd,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        do {
            _ = try await resolve([bundle], tool: .spades)
            XCTFail("two pairs of mate files cannot be one pair of R1 and R2 files")
        } catch let error as AssemblyReadSetResolutionError {
            guard case .unsupportedReadSet(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("Nothing is assembled on part of a sample"), message)
        }
    }

    // MARK: - Helpers

    private func resolve(
        _ inputs: [URL],
        tool: AssemblyTool,
        pairedEnd: Bool = false,
        explicitLayout: FASTQInputLayout? = nil,
        materializer: (any CLISequenceInputMaterializing & Sendable)? = nil
    ) async throws -> AssemblyResolvedInputs {
        try await AssemblyReadSetResolution.resolve(
            inputURLs: inputs,
            tool: tool,
            pairedEnd: pairedEnd,
            explicitLayout: explicitLayout,
            materializationDirectory: root.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true),
            materializer: materializer ?? fixtures.materializer
        )
    }

    private func reads(_ resolved: AssemblyResolvedInputs) throws -> [[String]] {
        try resolved.inputs.executionInputURLs.map(ReadSetFixtures.readNames(in:))
    }
}

/// Counts the bundles a resolution materializes.
private actor CountingMaterializer: CLISequenceInputMaterializing {
    private let base: any CLISequenceInputMaterializing & Sendable
    private(set) var calls = 0

    init(base: any CLISequenceInputMaterializing & Sendable) {
        self.base = base
    }

    func materialize(
        bundleURL: URL,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        calls += 1
        return try await base.materialize(bundleURL: bundleURL, tempDirectory: tempDirectory, progress: progress)
    }
}
