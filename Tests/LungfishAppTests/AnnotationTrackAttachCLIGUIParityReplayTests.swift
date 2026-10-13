// AnnotationTrackAttachCLIGUIParityReplayTests.swift - The annotation attach row against sequence attach-track
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A42 M3, plan decisions C3, C4, C5 and G1. The Import Center and a file dropped
// on the sidebar attach an annotation file to a reference bundle by launching `lungfish-cli
// sequence attach-track` through `CLIBundleEditRunner`, and their row records the argv it runs.
// Side A is the app's route, the begin helper and the runner both sites call, on the built CLI.
// Side C runs the row's command, rebased onto root C, with the built CLI. Side C' is the harness's
// replay of the command side C's record names. The case declares nothing.
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the
// integration tier, where the CLI is built.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class AnnotationTrackAttachCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case attachTrack
    }

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

    func testTheAttachRowWritesWhatSequenceAttachTrackWrites() async throws {
        var rowCommand: String?
        let result = try await harness.assertParity(
            Case.attachTrack,
            declared: [],
            in: scratch.appendingPathComponent("attach", isDirectory: true),
            fixture: { root in try self.writeFixture(root) },
            sideA: { root in
                let (outcome, command) = try await self.sideA(root)
                rowCommand = command
                return outcome
            },
            sideC: { root in try await self.sideC(root, rowCommand: rowCommand) }
        )
        XCTAssertEqual(result.runs.a.outcome.end, .completed, result.runs.a.outcome.detail)
        XCTAssertEqual(result.runs.a.outcome.detail, "Imported 2 annotations", "the row's complete words")
        XCTAssertEqual(result.runs.cPrime.outcome.end, .completed, result.runs.cPrime.outcome.detail)
    }

    // MARK: - The sides

    /// One reference bundle with an `imported` track, and a BED of two primers beside it.
    private func writeFixture(_ root: URL) throws {
        _ = try AnnotationEditRouteParityTests.makeBundle(in: root, inputs: scratch)
        try "chr1\t2\t9\tprimer-left\t0\t+\nchr1\t10\t15\tprimer-right\t0\t-\n"
            .write(to: root.appendingPathComponent("primers.bed"), atomically: true, encoding: .utf8)
    }

    /// Side A. The begin helper the two sites call, and the runner on the argv it hands them, with a
    /// hyphen-leading track name the sheet allows. Returns the outcome and the row's command.
    private func sideA(_ root: URL) async throws -> (RouteParitySideOutcome, String?) {
        let reporter = RecordingOperationReporter()
        let runner = CLIBundleEditRunner(cliURLOverride: harness.cliBinary)
        var outcome = RouteParitySideOutcome(end: .failed, detail: "the row did not start")
        await AppDelegate.beginAnnotationTrackImportOperation(
            annotationURL: root.appendingPathComponent("primers.bed"),
            bundleURL: root.appendingPathComponent("Fixture.lungfishref", isDirectory: true),
            trackID: "primers",
            trackName: "-primers v2",
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
        return (outcome, reporter.items.first?.cliCommand)
    }

    /// Side C. The row's command, rebased from root A onto `root`, run by the built CLI. It names the
    /// command its record holds for side C'.
    private func sideC(_ root: URL, rowCommand: String?) async throws -> RouteParitySideOutcome {
        let rootA = RouteParityHarness.root(of: .a, in: root.deletingLastPathComponent())
        let command = try RouteParityHarness.rebased(try XCTUnwrap(rowCommand, "side A's row recorded no command"), from: rootA, to: root)
        let arguments = try RouteParityHarness.arguments(ofLine: command)
        let run = await RouteParityHarness.runCLI(harness.cliBinary, arguments: arguments, timeout: .seconds(30))
        return RouteParitySideOutcome(end: run.end, detail: run.detail, recordedCommand: try Self.recordedCommand(in: root))
    }

    /// The command the attach's record in `root` names, written as a row writes one.
    private static func recordedCommand(in root: URL) throws -> String {
        let log = root.appendingPathComponent("Fixture.lungfishref/annotations/primers-import-provenance.json")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: log)) as? [String: Any])
        let entry = try XCTUnwrap((object["entries"] as? [[String: Any]])?.first)
        let argv = try XCTUnwrap(entry["argv"] as? [String])
        XCTAssertEqual(Array(argv.dropFirst().prefix(2)), ["sequence", "attach-track"], "\(argv)")
        return OperationCenter.buildCLICommand(subcommand: "sequence attach-track", args: Array(argv.dropFirst(3)))
    }
}
