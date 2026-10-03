// CLIReplayHarnessReplayTests.swift - The replay harness end to end, on a bam filter run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/contracts/CLI-EQUIVALENCE.md, "Tests that enforce it". The test copies
// one bundle into two sibling roots, runs the GUI path of row 47 (Create
// Filtered Alignment Track) on root A through its begin helper and the
// Workflow call its launch closure makes, rebases the recorded command onto
// root B, runs it in this process, and compares the two bundles. It runs
// samtools, so its class name ends in ReplayTests, which sends it to the
// integration tier (scripts/full-suite-gate.sh, REPLAY_SUITES).

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class CLIReplayHarnessReplayTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "cli-replay-harness")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testBAMFilterReplaysToTheSameBundle() async throws {
        let samtools = try XCTUnwrap(BamFixtureBuilder.locateSamtools(), "the replay needs samtools")
        let staging = scratch.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let fixture = try BundleAlignmentFixture.make(
            rootURL: staging,
            samtoolsPath: URL(fileURLWithPath: samtools),
            includeMappingResult: false
        )

        // 1. Two sibling roots with identical bytes.
        let rootA = scratch.appendingPathComponent("A", isDirectory: true)
        let rootB = scratch.appendingPathComponent("B", isDirectory: true)
        let bundleName = fixture.bundleURL.lastPathComponent
        for root in [rootA, rootB] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture.bundleURL, to: root.appendingPathComponent(bundleName))
        }
        let bundleA = rootA.appendingPathComponent(bundleName, isDirectory: true)
        let bundleB = rootB.appendingPathComponent(bundleName, isDirectory: true)
        OutputEquivalence.assertSame(bundleA, bundleB, kind: .bundle)

        // 2. The GUI path on root A: the begin helper, then the Workflow call
        // its launch closure makes.
        let request = AlignmentFilterInspectorLaunchRequest(
            sourceTrackID: fixture.sourceTrackID,
            outputTrackName: "Mapped Reads",
            filterRequest: AlignmentFilterRequest(mappedOnly: true, minimumMAPQ: 30)
        )
        let reporter = RecordingOperationReporter()
        var launched = false
        InspectorViewController.beginFilteredAlignmentWorkflowOperation(
            bundleURL: bundleA,
            serviceTarget: .bundle(bundleA),
            request: request,
            reporter: reporter
        ) { _ in launched = true }
        XCTAssertTrue(launched)
        _ = try await BundleAlignmentFilterService().deriveFilteredAlignment(
            target: .bundle(bundleA),
            sourceTrackID: request.sourceTrackID,
            outputTrackName: request.outputTrackName,
            filterRequest: request.filterRequest
        )
        let recorded = try XCTUnwrap(reporter.items.first?.cliCommand)
        let parsed = try RecordedCLICommand.parseScript(recorded)
        XCTAssertEqual(parsed.count, 1)

        // 3. Rebase onto root B, parse, and run in this process.
        let replay = try RecordedCLICommand.rebased(recorded, from: rootA, to: rootB)
        XCTAssertFalse(replay.contains(rootA.lastPathComponent + "/" + bundleName), replay)
        try await RecordedCLICommand.runInProcess(replay)

        // 4. The two bundles are the same bundle.
        OutputEquivalence.assertSame(bundleA, bundleB, kind: .bundle)
        XCTAssertNotEqual(
            try OutputEquivalence.differences(bundleA, fixture.bundleURL, kind: .bundle),
            [],
            "the run must have changed the bundle, or the comparison proves nothing"
        )

        // 5. A command with another setting does not replay the run. Without
        // the MAPQ threshold the low-MAPQ read survives, and the comparison
        // sees it.
        let rootC = scratch.appendingPathComponent("C", isDirectory: true)
        try FileManager.default.createDirectory(at: rootC, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.bundleURL, to: rootC.appendingPathComponent(bundleName))
        let bundleC = rootC.appendingPathComponent(bundleName, isDirectory: true)
        let looser = InspectorViewController.filteredAlignmentCLICommand(
            serviceTarget: .bundle(bundleA),
            request: AlignmentFilterInspectorLaunchRequest(
                sourceTrackID: fixture.sourceTrackID,
                outputTrackName: "Mapped Reads",
                filterRequest: AlignmentFilterRequest(mappedOnly: true)
            )
        )
        try await RecordedCLICommand.runInProcess(try RecordedCLICommand.rebased(looser, from: rootA, to: rootC))
        let found = try OutputEquivalence.differences(bundleA, bundleC, kind: .bundle)
        XCTAssertTrue(found.contains { $0.contains("records sha256") }, "\(found)")
    }

    func testRebasedRefusesAnArgumentThatNamesRootAElsewhere() throws {
        let rootA = scratch.appendingPathComponent("A", isDirectory: true)
        let rootB = scratch.appendingPathComponent("B", isDirectory: true)
        let embedded = OperationCenter.buildCLICommand(
            subcommand: "bam filter",
            args: ["--bundle=\(rootA.path)/x.lungfishref", "--alignment-track", "t"]
        )
        XCTAssertThrowsError(try RecordedCLICommand.rebased(embedded, from: rootA, to: rootB))
        let elsewhere = OperationCenter.buildCLICommand(
            subcommand: "bam filter",
            args: ["--bundle", "/tmp/other/x.lungfishref", "--alignment-track", "t"]
        )
        XCTAssertThrowsError(try RecordedCLICommand.rebased(elsewhere, from: rootA, to: rootB))
        let good = OperationCenter.buildCLICommand(
            subcommand: "bam filter",
            args: ["--bundle", rootA.appendingPathComponent("x.lungfishref").path, "--alignment-track", "t"]
        )
        XCTAssertEqual(
            try RecordedCLICommand.rebased(good, from: rootA, to: rootB),
            OperationCenter.buildCLICommand(
                subcommand: "bam filter",
                args: ["--bundle", rootB.appendingPathComponent("x.lungfishref").path, "--alignment-track", "t"]
            )
        )
    }

    // MARK: - OutputEquivalence on BAM files, which needs samtools

    func testBAMsMatchWhenOnlyTheirProgramLinesDiffer() throws {
        let samtools = try XCTUnwrap(BamFixtureBuilder.locateSamtools(), "the BAM comparison needs samtools")
        let (a, b) = try makeRoots()
        try makeBAM(at: a.appendingPathComponent("reads.bam"), names: ["r1", "r2"], samtools: samtools)
        try makeBAM(at: b.appendingPathComponent("reads.bam"), names: ["r1", "r2"], samtools: samtools)
        for root in [a, b] {
            try runSamtools(samtools, ["index", root.appendingPathComponent("reads.bam").path])
        }
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .files), [])
    }

    func testBAMsDifferWhenARecordDiffers() throws {
        let samtools = try XCTUnwrap(BamFixtureBuilder.locateSamtools(), "the BAM comparison needs samtools")
        let (a, b) = try makeRoots()
        try makeBAM(at: a.appendingPathComponent("reads.bam"), names: ["r1", "r2"], samtools: samtools)
        try makeBAM(at: b.appendingPathComponent("reads.bam"), names: ["r1", "r3"], samtools: samtools)
        let found = try OutputEquivalence.differences(a, b, kind: .files)
        XCTAssertEqual(found.count, 1, "\(found)")
        XCTAssertTrue(found[0].contains("records sha256"), found[0])
    }

    private func makeRoots() throws -> (URL, URL) {
        let a = scratch.appendingPathComponent("bamA-\(UUID().uuidString)", isDirectory: true)
        let b = scratch.appendingPathComponent("bamB-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        return (a, b)
    }

    private func makeBAM(at url: URL, names: [String], samtools: String) throws {
        let reads = names.enumerated().map { index, name in
            BamFixtureBuilder.Read(
                qname: name, flag: 0, rname: "chr1", pos: 10 + index * 5, mapq: 60, cigar: "10M",
                seq: "ACGTACGTAC", qual: "IIIIIIIIII"
            )
        }
        try BamFixtureBuilder.makeBAM(
            at: url,
            references: [BamFixtureBuilder.Reference(name: "chr1", length: 100)],
            reads: reads,
            samtoolsPath: samtools
        )
    }

    private func runSamtools(_ samtools: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: samtools)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
