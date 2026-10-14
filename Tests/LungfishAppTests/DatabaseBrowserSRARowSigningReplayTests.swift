// DatabaseBrowserSRARowSigningReplayTests.swift - The SRA browser's row keeps its signature on the CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L5 (the ruling of the A52 whole-lane review, Q6). The cases of
// DatabaseBrowserSRARowParityReplayTests run with no signing key. This one runs the row's ENA mirror way again with
// `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under the case root, on side A (the window's route
// before lane A45, the hidden key's `legacy` value), side C (`fetch sra download --bundle`) and side C' (the recorded
// command), and fails when the CLI route leaves unsigned a record the in-process route signs, or the bundle's record
// that the result opens first. The class declares nothing and compares no counts, since a signed record adds two
// files to each root.
//
// It launches the built lungfish-cli and the managed tools of the import, so its name ends in ReplayTests and it
// runs in the integration tier.

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class DatabaseBrowserSRARowSigningReplayTests: XCTestCase {
    private typealias Family = DatabaseBrowserSRARowParityReplayTests

    /// The imported bundle's record in a side root, which the run's record rewrite signs.
    private nonisolated static func openingRecord(in root: URL) -> URL {
        root.appendingPathComponent("Project.lungfish/Imports/\(SRAToolkitRecordedRunner.singleEndRun).lungfishfastq", isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    }

    func testAnENAMirrorRunLosesNoSignatureOnTheCLIRoute() async throws {
        // A batch with a project asks `AppDelegate.shared` whether the project is writable, which reads `NSApp`.
        _ = NSApplication.shared
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        let root = try TestTempDirectory.make(prefix: "sra-row-signing")
        addTeardownBlock { TestTempDirectory.cleanup(root) }

        let archives = SRAScriptedArchives()
        let recorded = SRAToolkitRecordedRunner(testFile: #filePath)
        let source = try XCTUnwrap(try recorded.recordedFiles(of: Family.run).first)
        let gzipped = root.appendingPathComponent("\(Family.run).fastq.gz")
        try KrakenOutputCompactor.gzipCopy(source: source, destination: gzipped)
        archives.listOnENA(
            Family.run, .init(layout: "SINGLE", files: [(name: gzipped.lastPathComponent, data: try Data(contentsOf: gzipped))]))
        let server = try SRAArchivesStandIn.start(serving: archives)
        defer { server.stop() }
        let scripts = root.appendingPathComponent("toolkit", isDirectory: true)
        try SRAToolkitStandInScripts.write(
            into: scripts, fixtures: SRAToolkitStandInScripts.fixturesFolder(testFile: #filePath))
        let saved = ProcessEnvironmentOverride(
            set: [
                NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString,
                ENAServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString,
                SRAToolkitStandInScripts.variable: scripts.path,
                "LUNGFISH_CLI_PATH": cli.path,
            ],
            unset: ["NCBI_API_KEY"])
        defer { saved.restore() }
        let legacy = makeTestDefaultsSuite(prefix: "DatabaseBrowserSRARowSigningReplayTests")
        legacy.defaults.set(SRARowDownloadRoute.legacy.rawValue, forKey: SRARowDownloadRouteSettings.defaultsKey)
        let viaCLI = makeTestDefaultsSuite(prefix: "DatabaseBrowserSRARowSigningReplayTests")
        viaCLI.defaults.set(SRARowDownloadRoute.cli.rawValue, forKey: SRARowDownloadRouteSettings.defaultsKey)

        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(180))
        let runs = try await harness.runSigned(
            in: root.appendingPathComponent("case", isDirectory: true),
            fixture: DatabaseBrowserNucleotideRowParityReplayTests.makeProject,
            sideA: { await Family.row(in: $0, suite: legacy.name) },
            sideC: { await Family.row(in: $0, suite: viaCLI.name) }
        )
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        RouteParityHarness.assertNoSignatureLost(runs, opening: Self.openingRecord)
        await harness.assertSignaturesVerify(runs, opening: Self.openingRecord)
    }
}
