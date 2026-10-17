// DatabaseBrowserSRARowParityReplayTests.swift - The SRA browser's row against the replay of its command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M3, panel decisions C4 and G5, on lane Q30's harness. One SRA run of the browser's
// download, with a project, runs on two sides that start as copies of one empty project. Side A, the
// in-process route of the hidden key's `legacy` value, went with its key in Phase 2.11 (K3).
//
// - Side C is the CLI route, `fetch sra download <run> --bundle --project <project> <the sheet's flags>
//   --format json` launched through `CLISubprocessTransport`, with the line the row recorded.
// - Side C' is the harness's replay of the row's recorded command.
//
// Both sides read one loopback server (`SRAArchivesStandIn`) that answers as scripted archives for ENA's
// portal and mirror and NCBI's run info, and the SRA Toolkit stand-in scripts, all named in the process
// environment. The cases are the row's two ways, a run ENA lists files for and a run ENA cannot serve,
// which takes the toolkit. The class launches the built lungfish-cli and the managed tools of the import,
// so its name ends in ReplayTests, which sends it to the integration tier.

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
final class DatabaseBrowserSRARowParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case toolkitRun
        case enaMirrorRun
    }

    static let run = SRAToolkitRecordedRunner.singleEndRun

    func testAToolkitRunImportsTheSameBundleOnBothRoutes() async throws {
        try await assertParity(.toolkitRun)
    }

    func testAnENAMirrorRunImportsTheSameBundleOnBothRoutes() async throws {
        try await assertParity(.enaMirrorRun)
    }

    func assertParity(_ parityCase: Case) async throws {
        // A batch with a project asks `AppDelegate.shared` whether the project is writable, which reads `NSApp`.
        _ = NSApplication.shared
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        let root = try TestTempDirectory.make(prefix: "sra-row-parity")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let archives = try scripted(parityCase, in: root)
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
        let suite = makeTestDefaultsSuite(prefix: "DatabaseBrowserSRARowParityReplayTests")

        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(180))
        let runs = try await ReadsRouteParity.runCAndCPrime(
            harness,
            in: root.appendingPathComponent("case", isDirectory: true),
            fixture: DatabaseBrowserNucleotideRowParityReplayTests.makeProject,
            sideC: { await Self.row(in: $0, suite: suite.name) }
        )
        let result = try harness.evaluate(parityCase, declared: [], runs: runs)
        RouteParityHarness.assertNoFailures(result.failures, in: "\(parityCase)")

        // The toolkit case logs the fallback from ENA as a warning on every side, so each ends with warnings.
        let expectedEnd: RouteParityEnd = parityCase == .toolkitRun ? .completedWithWarnings : .completed
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, expectedEnd, "side \(run.side): \(run.outcome.detail)")
        }
        XCTAssertEqual(runs.cPrime.replayedArguments.map { Array($0.prefix(4)) }, [["fetch", "sra", "download", Self.run]])
        for run in runs.all {
            let bundle = Self.bundle(in: run.root)
            XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path), "side \(run.side) imported no bundle")
            // B-5 over every record of the bundle, on both sides. Side A's stale sidecar digest went with the
            // in-process route and its key (BIO ruling on lane A45 M3c, section b item 3, Phase 2.11 K3).
            try FetchSRAFetchedRecordReplayTests.assertEveryRecordNamesItsFilesInTheBundle(
                bundle, side: "side \(run.side)")
        }
    }

    // MARK: - Sides

    /// One SRA run of the browser's download into the project of `root`, with the defaults of `suite`, and
    /// how its row ended. The row records the command, which side C' replays.
    static func row(in root: URL, suite: String) async -> RouteParitySideOutcome {
        let project = DatabaseBrowserNucleotideRowParityReplayTests.project(in: root)
        let viewModel = DatabaseBrowserViewModel(
            source: .ena, ncbiService: NCBIService(apiKey: nil), enaService: ENAService(), sraDownloadSuiteName: suite)
        viewModel.routeContext = OperationRouteContext(projectURL: project, windowStateScopeID: UUID())
        let id = OperationCenter.shared.begin(
            title: "SRA row parity", detail: "Starting...", operationType: .download, cliCommand: nil).rowID
        defer { OperationCenter.shared.clearItem(id: id) }
        viewModel.startSRADownloadTask(
            records: [SearchResultRecord(id: run, accession: run, title: run, source: .ena)],
            importConfig: sheet(), downloadCenterTaskID: id, totalCount: 1)
        let item = { OperationCenter.shared.items.first { $0.id == id } }
        let ended = await LungfishTestSupport.waitUntil(timeout: .seconds(240)) { item()?.state.isActive == false }
        guard ended, let final = item() else {
            return RouteParitySideOutcome(end: .failed, detail: "the row never ended: \(String(describing: item()?.state))")
        }
        // A row that logged a warning ends with warnings, as the CLI's exit does for the same events.
        let warned = final.logEntries.contains { $0.level == .warning }
        let end: RouteParityEnd = switch final.state {
        case .completed: warned ? .completedWithWarnings : .completed
        case .cancelled: .cancelled
        default: .failed
        }
        let detail = final.logEntries.suffix(3).map(\.message).joined(separator: " | ")
        return RouteParitySideOutcome(end: end, detail: detail, recordedCommand: final.cliCommand)
    }

    /// The Import sheet left as it proposes: auto platform, fast compression, no storage tool.
    static func sheet() -> FASTQImportConfiguration {
        FASTQImportConfiguration(
            inputFiles: [], detectedPlatform: .illumina, confirmedPlatform: .illumina, pairingMode: .singleEnd,
            qualityBinning: .none, skipClumpify: true, deleteOriginals: false, postImportRecipe: nil,
            resolvedPlaceholders: [:], recipeName: nil, compressionLevel: .fast)
    }

    // MARK: - Helpers

    /// ENA's portal and mirror and NCBI's run info, scripted for `parityCase`. The toolkit case takes ENA
    /// down, and NCBI lists the run. The mirror case lists the recorded run's gzipped file on ENA.
    private func scripted(_ parityCase: Case, in root: URL) throws -> SRAScriptedArchives {
        let archives = SRAScriptedArchives()
        switch parityCase {
        case .toolkitRun:
            archives.takeENADown()
            archives.listOnNCBI(Self.run, layout: "SINGLE")
        case .enaMirrorRun:
            let recorded = SRAToolkitRecordedRunner(testFile: #filePath)
            let source = try XCTUnwrap(try recorded.recordedFiles(of: Self.run).first)
            let gzipped = root.appendingPathComponent("\(Self.run).fastq.gz")
            try KrakenOutputCompactor.gzipCopy(source: source, destination: gzipped)
            archives.listOnENA(
                Self.run, .init(layout: "SINGLE", files: [(name: gzipped.lastPathComponent, data: try Data(contentsOf: gzipped))]))
        }
        return archives
    }

    static func bundle(in root: URL) -> URL {
        DatabaseBrowserNucleotideRowParityReplayTests.project(in: root)
            .appendingPathComponent("Imports/\(run).lungfishfastq", isDirectory: true)
    }
}
