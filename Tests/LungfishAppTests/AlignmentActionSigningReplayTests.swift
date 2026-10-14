// AlignmentActionSigningReplayTests.swift - The Viewer and Inspector alignment actions keep their signatures on the CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L3 (the ruling of the A52 whole-lane review, Q6). The cases of
// AlignmentActionCLIGUIParityReplayTests run with no signing key. These run three of its sides again with
// `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under the case root, on side A (the in-process
// service), side C (the app's begin helper and the L3 runner) and side C' (the recorded command), and fail when
// the CLI route leaves unsigned a record the in-process route signs, or the record the result opens first.
// The sides of that class are reused (they are internal for it), and side C is run here.
//
// - Remove track. `BundleAlignmentTrackRemovalRecord` writes the record that stays in the bundle.
// - Consensus bundle. `AlignmentConsensusPublicationService` writes the new bundle's record.
// - Selected reads. `AlignmentReadExtractionPublisher` writes the new FASTQ bundle's record.
//
// It launches the built lungfish-cli and runs samtools, so its name ends in ReplayTests and it runs in the
// integration tier.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class AlignmentActionSigningReplayTests: XCTestCase {
    private typealias Family = AlignmentActionCLIGUIParityReplayTests

    private var scratch: URL!
    private var cli: URL!
    private var harness: RouteParityHarness!

    override func setUp() async throws {
        try await super.setUp()
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    override func setUpWithError() throws {
        guard BamFixtureBuilder.locateSamtools() != nil else {
            try ToolAvailability.skipOrFail("samtools is not available, so the bundles cannot be compared")
        }
        scratch = try TestTempDirectory.make(prefix: "alignment-action-signing")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
    }

    override func tearDownWithError() throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
    }

    private func assertCompleted(_ runs: RouteParityRuns) {
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
    }

    /// The signature checks every case ends with.
    private func assertSigned(_ runs: RouteParityRuns, opening: @escaping @Sendable (URL) -> URL) async {
        assertCompleted(runs)
        RouteParityHarness.assertNoSignatureLost(runs, opening: opening)
        await harness.assertSignaturesVerify(runs, opening: opening)
    }

    // MARK: - Remove track

    private func removeTrackSideC(_ root: URL) async throws -> RouteParitySideOutcome {
        let bundleURL = DerivedAlignmentTrackFixture.existing(in: root).bundleURL
        let trackID = DerivedAlignmentTrackFixture.derivedTrackID
        let reporter = RecordingOperationReporter()
        var launched: UUID?
        InspectorViewController.beginRemoveDerivedAlignmentOperation(
            trackName: DerivedAlignmentTrackFixture.derivedTrackName,
            trackID: trackID, bundleURL: bundleURL, routeContext: nil, reporter: reporter
        ) { launched = $0 }
        let id = try XCTUnwrap(launched, "the row started")
        let outcome = await withCheckedContinuation { continuation in
            InspectorViewController.runRemoveDerivedAlignmentThroughCLI(
                bundleURL: bundleURL, trackID: trackID, operationID: id, runner: CLIAlignmentActionRunner(cliURLOverride: cli)
            ) { continuation.resume(returning: $0) }
        }
        let command = reporter.items.first?.cliCommand
        switch outcome {
        case .success(let completion):
            return RouteParitySideOutcome(end: .completed, detail: completion.message ?? "", recordedCommand: command)
        case .failure(let error):
            return RouteParitySideOutcome(end: .failed, detail: error.localizedDescription, recordedCommand: command)
        }
    }

    func testRemovingADerivedTrackLosesNoSignatureOnTheCLIRoute() async throws {
        let trackID = DerivedAlignmentTrackFixture.derivedTrackID
        let runs = try await harness.runSigned(
            in: scratch.appendingPathComponent("remove-track", isDirectory: true),
            fixture: { try Family.makeFixture(in: $0) },
            sideA: { await Family.sideA($0, trackID: trackID) },
            sideC: { try await self.removeTrackSideC($0) }
        )
        await assertSigned(runs) {
            BundleAlignmentTrackRemovalRecord.recordURL(
                bundleURL: DerivedAlignmentTrackFixture.existing(in: $0).bundleURL, trackID: DerivedAlignmentTrackFixture.derivedTrackID
            )
        }
    }

    // MARK: - Consensus bundle

    private func consensusSideC(_ root: URL, output: String) async throws -> RouteParitySideOutcome {
        let (context, export) = try Family.consensusRequest(in: root, minimumDepth: 1)
        let invocation = AlignmentConsensusInvocation(
            context: context, region: export.region, consensusRequest: export.consensusRequest,
            recordName: export.recordName, output: root.appendingPathComponent(output).path
        )
        var launched: UUID?
        ViewerViewController.beginAlignmentConsensusGenerationOperation(invocation: invocation) { launched = $0 }
        let id = try XCTUnwrap(launched, "the row started")
        let runner = CLIAlignmentActionRunner(cliURLOverride: cli)
        let outcome = await withCheckedContinuation { continuation in
            ViewerViewController.runAlignmentConsensusThroughCLI(
                invocation: invocation, workingDirectory: nil, operationID: id, runner: runner,
                confirmAllLowDepth: { true }, finish: { continuation.resume(returning: $0) }
            )
        }
        let command = OperationCenter.shared.items.first { $0.id == id }?.cliCommand
        switch outcome {
        case .success(let completion):
            _ = OperationCenter.shared.complete(id: id, detail: completion.message ?? "")
            return RouteParitySideOutcome(end: .completed, detail: completion.message ?? "", recordedCommand: command)
        case .failure(let error):
            _ = OperationCenter.shared.fail(id: id, detail: "Alignment consensus failed", errorMessage: error.localizedDescription)
            return RouteParitySideOutcome(end: .failed, detail: error.localizedDescription, recordedCommand: command)
        }
    }

    func testAConsensusBundleLosesNoSignatureOnTheCLIRoute() async throws {
        let output = "out/S1.lungfishref"
        let runs = try await harness.runSigned(
            in: scratch.appendingPathComponent("consensus-bundle", isDirectory: true),
            fixture: { try Family.makeConsensusFixture(in: $0) },
            sideA: { await Family.consensusSideA($0, output: output, minimumDepth: 1) },
            sideC: { try await self.consensusSideC($0, output: output) }
        )
        await assertSigned(runs) { $0.appendingPathComponent("\(output)/\(ProvenanceRecorder.provenanceFilename)") }
    }

    // MARK: - Selected reads

    private func selectedReadsSideC(_ root: URL) async throws -> RouteParitySideOutcome {
        let (context, invocation) = try Family.readsRequest(in: root, selected: true)
        let reporter = RecordingOperationReporter()
        var launched: UUID?
        ViewerViewController.beginAlignmentReadExtractionOperation(
            title: "Extract Selected Reads", detail: "Preparing…",
            invocation: invocation, evidence: context.identity, routeContext: nil, reporter: reporter
        ) { launched = $0 }
        let id = try XCTUnwrap(launched, "the row started")
        let command = reporter.items.first?.cliCommand
        let outcome = await withCheckedContinuation { continuation in
            ViewerViewController.runReadExtractionThroughCLI(
                arguments: ViewerViewController.alignmentReadExtractionCLIArguments(invocation),
                operationID: id,
                runner: CLIAlignmentActionRunner(cliURLOverride: cli)
            ) { continuation.resume(returning: $0) }
        }
        switch outcome {
        case .success:
            return RouteParitySideOutcome(end: .completed, detail: "Alignment read extraction published", recordedCommand: command)
        case .failure(let error):
            return RouteParitySideOutcome(end: .failed, detail: error.localizedDescription, recordedCommand: command)
        }
    }

    func testSelectedReadsLoseNoSignatureOnTheCLIRoute() async throws {
        let runs = try await harness.runSigned(
            in: scratch.appendingPathComponent("selected-reads", isDirectory: true),
            fixture: { try Family.makeReadsFixture(in: $0) },
            sideA: { await Family.readsSideA($0, selected: true) },
            sideC: { try await self.selectedReadsSideC($0) }
        )
        await assertSigned(runs) { $0.appendingPathComponent("out/S1.lungfishfastq/\(ProvenanceRecorder.provenanceFilename)") }
    }
}
