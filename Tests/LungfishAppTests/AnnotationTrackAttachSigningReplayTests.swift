// AnnotationTrackAttachSigningReplayTests.swift - An attached annotation track keeps its signature on the CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L1 (the ruling of the A52 whole-lane review, Q6). The case of
// AnnotationTrackAttachCLIGUIParityReplayTests runs with no signing key. This one runs its attach again with
// `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under the case root, on side A (the in-process
// attach), side C (the begin helper and `CLIBundleEditRunner` launching `sequence attach-track`) and side C' (the
// recorded command), and fails when the CLI route leaves unsigned a record the in-process route signs, or the
// bundle's record that the result opens first.
// ReferenceBundleAnnotationImportSigningReplayTests is the narrow test of the writer behind the record.
//
// It launches the built lungfish-cli, so its name ends in ReplayTests and it runs in the integration tier.

import Foundation
import LungfishCore
import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class AnnotationTrackAttachSigningReplayTests: XCTestCase {
    /// The track the sheet names, with a hyphen-leading name the sheet allows.
    private static let trackID = "primers"
    private static let trackName = "-primers v2"

    /// The bundle's record in a side root, which the attach rewrites and the result opens first.
    private nonisolated static func openingRecord(in root: URL) -> URL {
        root.appendingPathComponent("Fixture.lungfishref", isDirectory: true)
            .appendingPathComponent(ProvenanceWriter.provenanceFilename)
    }

    func testAnAttachedTrackLosesNoSignatureOnTheCLIRoute() async throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        let scratch = try TestTempDirectory.make(prefix: "attach-track-signing")
        defer { TestTempDirectory.cleanup(scratch) }
        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(30))
        let runs = try await harness.runSigned(
            in: scratch.appendingPathComponent("attach", isDirectory: true),
            fixture: { root in try self.writeFixture(root, inputs: scratch) },
            sideA: { root in await self.sideA(root, cli: cli) },
            sideC: { root in await self.sideC(root, cli: cli) }
        )
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        RouteParityHarness.assertNoSignatureLost(runs, opening: Self.openingRecord)
        await harness.assertSignaturesVerify(runs, opening: Self.openingRecord)
    }

    // MARK: - The sides

    /// One reference bundle with an `imported` track, and a BED of two primers beside it.
    private func writeFixture(_ root: URL, inputs: URL) throws {
        _ = try AnnotationEditRouteParityTests.makeBundle(in: root, inputs: inputs)
        try "chr1\t2\t9\tprimer-left\t0\t+\nchr1\t10\t15\tprimer-right\t0\t-\n"
            .write(to: root.appendingPathComponent("primers.bed"), atomically: true, encoding: .utf8)
    }

    /// Side A. The in-process attach both sites made at the base, with the track side C names.
    private func sideA(_ root: URL, cli: URL) async -> RouteParitySideOutcome {
        let source = root.appendingPathComponent("primers.bed")
        let bundle = root.appendingPathComponent("Fixture.lungfishref", isDirectory: true)
        let argv = [cli.path]
            + ReferenceBundleAnnotationImportService.attachTrackArguments(
                sourceURL: source, bundleURL: bundle, trackID: Self.trackID, trackName: Self.trackName
            )
            + ["--format", "json"]
        do {
            let result = try await ReferenceBundleAnnotationImportService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).attachAnnotationTrack(
                sourceURL: source,
                bundleURL: bundle,
                trackID: Self.trackID,
                trackName: Self.trackName,
                invocationArgv: argv
            )
            return RouteParitySideOutcome(end: .completed, detail: "Imported \(result.featureCount) annotations")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// Side C. The begin helper the two sites call, and the runner on the argv it hands them, which launches
    /// the built CLI. It returns the row's command, which side C' replays.
    private func sideC(_ root: URL, cli: URL) async -> RouteParitySideOutcome {
        let reporter = RecordingOperationReporter()
        let runner = CLIBundleEditRunner(cliURLOverride: cli)
        var outcome = RouteParitySideOutcome(end: .failed, detail: "the row did not start")
        await AppDelegate.beginAnnotationTrackImportOperation(
            annotationURL: root.appendingPathComponent("primers.bed"),
            bundleURL: root.appendingPathComponent("Fixture.lungfishref", isDirectory: true),
            trackID: Self.trackID,
            trackName: Self.trackName,
            routeContext: nil,
            reporter: reporter
        ) { id, arguments in
            do {
                let result = try await runner.run(arguments: arguments, operationID: id)
                outcome = RouteParitySideOutcome(end: .completed, detail: result.message ?? "")
            } catch {
                outcome = RouteParitySideOutcome(end: .failed, detail: "\(error)")
            }
        }
        return RouteParitySideOutcome(
            end: outcome.end, detail: outcome.detail, recordedCommand: reporter.items.first?.cliCommand
        )
    }
}
