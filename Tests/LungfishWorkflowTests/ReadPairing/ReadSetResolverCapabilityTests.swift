// ReadSetResolverCapabilityTests.swift - The form each capability gives a sample of pairs and single reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class ReadSetResolverCapabilityTests: XCTestCase {
    private var root: URL!
    private var fixtures: ReadSetFixtures!
    private var workDirectory: URL!
    private var resolver: ReadSetResolver!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "read-set-capabilities")
        fixtures = try ReadSetFixtures(in: root)
        workDirectory = root.appendingPathComponent("work", isDirectory: true)
        resolver = ReadSetResolver(materializationDirectory: workDirectory, materializer: fixtures.materializer)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func names(_ url: URL) throws -> [String] {
        try ReadSetFixtures.readNames(in: url)
    }

    // MARK: - One stream paired by name

    func testStreamToolGetsAMergeDerivativeInterleavedByName() async throws {
        let plan = try await resolver.plan(for: fixtures.mergeDerivative, capability: .bothInOneRunAsNameInterleavedStream)
        XCTAssertEqual(plan.runs.count, 1)
        XCTAssertTrue(plan.matePairs.isEmpty)
        XCTAssertTrue(plan.singleReads.isEmpty)
        let stream = try XCTUnwrap(plan.mixedStreams.first)
        XCTAssertEqual(try names(stream.url), ["u1/1", "u1/2", "x1", "x2", "x3"])
        XCTAssertEqual(stream.pairCount, 1)
        XCTAssertEqual(stream.singleReadCount, 3)
        XCTAssertEqual(stream.singleReadRole, .merged)
        XCTAssertEqual(plan.steps.map(\.kind), [.interleaveByName])
        XCTAssertEqual(plan.steps[0].inputURLs.map(\.lastPathComponent), ["unmerged_R1.fastq", "unmerged_R2.fastq", "merged.fastq"])
        XCTAssertEqual(plan.composition.fragmentCount, 4)
    }

    func testStreamToolGetsAMixedRootFileAsItIs() async throws {
        let plan = try await resolver.plan(for: fixtures.mixedRoot, capability: .bothInOneRunAsNameInterleavedStream)
        XCTAssertEqual(plan.mixedStreams.map(\.url), [fixtures.mixedRoot.appendingPathComponent("reads.fastq").standardizedFileURL])
        XCTAssertEqual(plan.mixedStreams.first?.pairCount, 2, "the sidecar records the counts")
        XCTAssertEqual(plan.mixedStreams.first?.singleReadCount, 3)
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertFalse(plan.recordsNothingNew, "the sample still holds pairs and single reads")
    }

    func testStreamToolStopsWhenMateNamesDisagree() async throws {
        let r1 = root.appendingPathComponent("loose_R1.fastq")
        let r2 = root.appendingPathComponent("loose_R2.fastq")
        let merged = root.appendingPathComponent("loose_merged.fastq")
        try ReadSetFixtures.fastq(["a1/1", "a2/1"]).write(to: r1, atomically: true, encoding: .utf8)
        try ReadSetFixtures.fastq(["a1/2", "zz/2"]).write(to: r2, atomically: true, encoding: .utf8)
        try ReadSetFixtures.fastq(["m1"]).write(to: merged, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try resolver.plan(r1: r1, r2: r2, singleReads: [merged], capability: .bothInOneRunAsNameInterleavedStream)) { error in
            guard case ReadSetResolverError.mateNameMismatch = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDirectory.path), "a failed plan leaves no file behind")
    }

    // MARK: - Separate files and per-kind runs

    func testLooseFilesNamedByRoleArePlannedAsGiven() throws {
        let r1 = fixtures.pairedDerivative.appendingPathComponent("sample_R1.fastq")
        let r2 = fixtures.pairedDerivative.appendingPathComponent("sample_R2.fastq")
        let merged = fixtures.mergeDerivative.appendingPathComponent("merged.fastq")
        let plan = try resolver.plan(r1: r1, r2: r2, singleReads: [merged], singleReadRole: .merged, capability: .bothInOneRunAsSeparateFiles)
        XCTAssertEqual(plan.sourceLayout, .pairedFilesWithSingleReads)
        XCTAssertEqual(plan.executionURLs, [r1, r2, merged].map(\.standardizedFileURL))
        XCTAssertEqual(plan.singleReads.map(\.role), [.merged])
        XCTAssertTrue(plan.steps.isEmpty)
    }

    func testPerKindToolGetsARunOfPairsAndARunOfSingleReads() async throws {
        let derivative = try await resolver.plan(for: fixtures.mergeDerivative, capability: .pairsOrSinglesPerRun)
        XCTAssertEqual(derivative.runs.count, 2)
        XCTAssertEqual(derivative.runs[0].executionURLs.map(\.lastPathComponent), ["unmerged_R1.fastq", "unmerged_R2.fastq"])
        XCTAssertEqual(derivative.runs[1].executionURLs.map(\.lastPathComponent), ["merged.fastq"])
        XCTAssertTrue(derivative.steps.isEmpty)

        let mixedRoot = try await resolver.plan(for: fixtures.mixedRoot, capability: .pairsOrSinglesPerRun)
        XCTAssertEqual(mixedRoot.steps.map(\.kind), [.splitByName])
        XCTAssertEqual(mixedRoot.runs.count, 2)
        XCTAssertEqual(mixedRoot.runs[0].matePairs.first?.pairCount, 2)
        XCTAssertEqual(mixedRoot.runs[1].singleReads.first?.readCount, 3)
    }

    func testPerKindToolGetsOneRunForAPairsOnlySample() async throws {
        let plan = try await resolver.plan(for: fixtures.pairedDerivative, capability: .pairsOrSinglesPerRun)
        XCTAssertEqual(plan.runs.count, 1)
        XCTAssertTrue(plan.recordsNothingNew)
    }

    // MARK: - Pairs only when the whole sample is paired

    /// Manager ruling 2026-10-03. EsViritu, TaxTriage and Viral Recon run a
    /// sample that mixes merged reads and pairs with every read single-end,
    /// state that, and drop no read.
    func testSamplesheetToolRunsAMixedSampleAllSingleAndSaysWhy() async throws {
        let plan = try await resolver.plan(for: fixtures.mergeDerivative, capability: .pairsOnlyWhenAllPaired)
        XCTAssertTrue(plan.matePairs.isEmpty)
        XCTAssertEqual(plan.singleReads.map(\.url.lastPathComponent), ["unmerged_R1.fastq", "unmerged_R2.fastq", "merged.fastq"])
        XCTAssertEqual(plan.singleReads.map(\.role), [.pairsRunAsSingle, .pairsRunAsSingle, .merged])
        let reason = try XCTUnwrap(plan.singleReadReason)
        XCTAssertTrue(reason.contains("every read runs as a single read"), reason)
        XCTAssertTrue(reason.contains("No read is left out"), reason)
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertEqual(plan.composition.fragmentCount, 4, "fragments are counted as the sample holds them")

        let mixedRoot = try await resolver.plan(for: fixtures.mixedRoot, capability: .pairsOnlyWhenAllPaired)
        XCTAssertEqual(mixedRoot.singleReads.map(\.url), [fixtures.mixedRoot.appendingPathComponent("reads.fastq").standardizedFileURL])
        XCTAssertNotNil(mixedRoot.singleReadReason)
    }

    func testSamplesheetToolPairsAPairsOnlySample() async throws {
        let plan = try await resolver.plan(for: fixtures.pairedDerivative, capability: .pairsOnlyWhenAllPaired)
        XCTAssertEqual(plan.matePairs.count, 1)
        XCTAssertNil(plan.singleReadReason)
        XCTAssertTrue(plan.recordsNothingNew)
    }

    // MARK: - Single reads only

    func testSingleReadToolGetsEveryFileAsSingleReadsWithNothingRecorded() async throws {
        let plan = try await resolver.plan(for: fixtures.interleavedRoot, capability: .singleReadsOnly)
        XCTAssertEqual(plan.singleReads.map(\.role), [.pairsRunAsSingle])
        XCTAssertNil(plan.singleReadReason)
        XCTAssertTrue(plan.recordsNothingNew)
    }

    // MARK: - Counting and provenance

    func testCountingReadsFillsTheComposition() async throws {
        let counting = ReadSetResolver(materializationDirectory: workDirectory, materializer: fixtures.materializer, countReads: true)
        let single = try await counting.plan(for: fixtures.singleRoot, capability: .bothInOneRunAsSeparateFiles)
        XCTAssertEqual(single.composition.singleEndReads, 3)
        XCTAssertEqual(single.composition.fragmentCount, 3)
        let interleaved = try await counting.plan(for: fixtures.interleavedRoot, capability: .bothInOneRunAsSeparateFiles)
        XCTAssertEqual(interleaved.composition.pairedFragments, 2)
        let paired = try await counting.plan(for: fixtures.pairedDerivative, capability: .bothInOneRunAsSeparateFiles)
        XCTAssertEqual(paired.composition.fragmentCount, 2)
    }

    func testSplitStepBecomesAProvenanceStepWithItsCounts() async throws {
        let plan = try await resolver.plan(for: fixtures.mixedRoot, capability: .bothInOneRunAsSeparateFiles)
        let step = try XCTUnwrap(plan.steps.first).stepExecution(toolVersion: "test")
        XCTAssertEqual(step.toolName, "Lungfish Read-Set Split")
        XCTAssertEqual(step.inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["reads.fastq"])
        XCTAssertEqual(step.outputs.count, 3)
        XCTAssertEqual(step.resolvedOptions?["pairs"], .integer(2))
        XCTAssertEqual(step.resolvedOptions?["singleReads"], .integer(3))
        XCTAssertEqual(step.exitCode, 0)
    }

    func testProvenanceParametersNameTheCapabilityAndCounts() async throws {
        let plan = try await resolver.plan(for: fixtures.mergeDerivative, capability: .pairsOnlyWhenAllPaired)
        guard case .dictionary(let values) = plan.provenanceParameters["readSetPlan"] else {
            return XCTFail("a mixed sample records its plan")
        }
        XCTAssertEqual(values["capability"], .string("pairs_only_when_all_paired"))
        XCTAssertEqual(values["pairedFragments"], .integer(1))
        XCTAssertEqual(values["mergedReads"], .integer(3))
        XCTAssertNotNil(values["singleReadReason"]?.stringValue)
    }
}
