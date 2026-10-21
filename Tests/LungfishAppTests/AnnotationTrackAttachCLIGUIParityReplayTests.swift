// AnnotationTrackAttachCLIGUIParityReplayTests.swift - The annotation attach in process against sequence attach-track
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A42 M3 and its review's Fix 4, plan decisions C3, C4, C5 and G1, on lane Q30's
// harness. The Import Center and a file dropped on the sidebar attach an annotation file to a
// reference bundle. One case runs on three sides that start as copies of one bundle and one BED.
//
// - Side A is the in-process route at the base, the call both sites made,
//   `ReferenceBundleAnnotationImportService.attachAnnotationTrack`. Its record names the argv side
//   C's command records, the change of the recorded command the closed gaps intend
//   (docs/contracts/CLI-EQUIVALENCE.md), so A against C compares everything else.
// - Side C is the CLI route, the begin helper both sites call and `CLIBundleEditRunner`, which
//   launches the built `lungfish-cli sequence attach-track`. Its row records the command.
// - Side C' is the harness's replay of that command.
//
// The case declares nothing, so A against C and C against C' are both empty (C4).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the
// integration tier, where the CLI is built.

import Foundation
import LungfishCore
import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class AnnotationTrackAttachCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case attachTrack
    }

    /// The track the sheet names, with a hyphen-leading name the sheet allows.
    private static let trackID = "primers"
    private static let trackName = "-primers v2"

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "attach-track-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(30))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testTheAttachRowWritesWhatTheInProcessAttachWrote() async throws {
        let result = try await harness.assertParity(
            Case.attachTrack,
            declared: [],
            in: scratch.appendingPathComponent("attach", isDirectory: true),
            fixture: { root in try self.writeFixture(root) },
            sideA: { root in await self.sideA(root) },
            sideC: { root in await self.sideC(root) }
        )
        XCTAssertEqual(result.runs.a.outcome.end, .completed, result.runs.a.outcome.detail)
        XCTAssertEqual(result.runs.a.outcome.detail, "Imported 2 annotations", "the row's complete words")
        XCTAssertEqual(result.runs.c.outcome.end, .completed, result.runs.c.outcome.detail)
        XCTAssertEqual(result.runs.c.outcome.detail, "Imported 2 annotations", "the row's complete words")
        XCTAssertEqual(result.runs.cPrime.outcome.end, .completed, result.runs.cPrime.outcome.detail)
    }

    // MARK: - The sides

    /// One reference bundle with an `imported` track, and a BED of two primers beside it.
    private func writeFixture(_ root: URL) throws {
        _ = try AnnotationEditRouteParityTests.makeBundle(in: root, inputs: scratch)
        try "chr1\t2\t9\tprimer-left\t0\t+\nchr1\t10\t15\tprimer-right\t0\t-\n"
            .write(to: root.appendingPathComponent("primers.bed"), atomically: true, encoding: .utf8)
    }

    /// Side A. The in-process attach both sites made at the base, with the track side C names.
    /// Its record names the argv side C's command records, which starts with the path the
    /// transport launched, as the command records its observed argv.
    private func sideA(_ root: URL) async -> RouteParitySideOutcome {
        let source = root.appendingPathComponent("primers.bed")
        let bundle = root.appendingPathComponent("Fixture.lungfishref", isDirectory: true)
        let argv = [harness.cliBinary.path]
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

    /// Side C. The begin helper the two sites call, and the runner on the argv it hands them,
    /// which launches the built CLI. It returns the row's command, which side C' replays.
    private func sideC(_ root: URL) async -> RouteParitySideOutcome {
        let reporter = RecordingOperationReporter()
        let runner = CLIBundleEditRunner(cliURLOverride: harness.cliBinary)
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
