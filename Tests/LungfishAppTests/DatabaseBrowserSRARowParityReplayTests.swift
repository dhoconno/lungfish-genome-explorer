// DatabaseBrowserSRARowParityReplayTests.swift - The SRA browser's row, in process against lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M3, panel decisions C4 and G5, on lane Q30's harness. One SRA run of the browser's
// download, with a project, runs on three sides that start as copies of one empty project.
//
// - Side A is the route before lane A45, the hidden key's `legacy` value. The app downloads the run,
//   runs the SRA Toolkit when ENA cannot serve it, imports on `CLIImportRunner` and writes the record
//   after the import child exits, all in the app process.
// - Side C is the CLI route, `fetch sra download <run> --bundle --project <project> <the sheet's flags>
//   --format json` launched through `CLISubprocessTransport`, with the line the row recorded.
// - Side C' is the harness's replay of the row's recorded command.
//
// Both routes read one loopback server (`SRAArchivesStandIn`) that answers as scripted archives for ENA's
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

    static let closer = "2.11, which deletes the in-process SRA row with its key (C4)"

    /// Each way side C differs from side A with BIO's reason, as measured (the counts are exact). Only the
    /// two record folders differ: the root record and the three records of `provenance/`. The payload, the
    /// sidecar and every other file are the same on both routes, and C against C' is empty, which the
    /// harness checks in both cases (BIO ruling on lane A45 M3c, section c item 2). The ENA mirror case and
    /// the toolkit case count separately, and the staged folder's name holds a UUID.
    static let declared: [RouteParityDeclaredDifference<Case>] = {
        let command = "The CLI route's record states the run's own command. The leaf's argument vector, its replay command and "
            + "its explicit cliCommand are `fetch sra download <run> --bundle ...`, and the steps it merges from the import "
            + "carry the same line, where the window's record states the `import fastq <staged FASTQ> ...` child it launched "
            + "(ruling A45-M3 section 1, the run-level argv)."
        let staging = "The window stages the run in .tmp/sra-batch-<UUID>/ and the leaf in .tmp/fetch-sra-<UUID>/, so each path "
            + "a record names under the staging folder differs, in the options' staging inputs, the outputs and the inputs and "
            + "outputs of the steps (ruling A45-M3 section 3)."
        let ids = "A record's id and the ids of its steps are UUIDs numbered by their first place in the tree. The two trees "
            + "hold other ids ahead of these, because the per-output records are other runs' records and the leaf adds a "
            + "step, so the numbers differ (ruling A45-M3 section 1, the ids)."
        let files = "The window writes its record after the import child wrote its own and lists the import's files a second "
            + "time, two more in the ENA mirror case and four more in the toolkit case, where the leaf writes one record "
            + "that lists each file once. The files after the sixth hold other entries, and the staged paths differ "
            + "(ruling A45-M3 section 1, one record per child, written last)."
        let removal = "The leaf's record names the removal of the staged FASTQ files as a last step (2.8 P1), which the window's "
            + "record lacks, so every field of that step exists only on side C: its tool, its times, its dependency list, "
            + "its inputs with their digests and sizes, and its options (ruling A45-M3 section 1, the step the child adds)."
        let focused = "C's per-output records are the run's own record focused on each output "
            + "(`ProvenanceEnvelope.focusedOnOutput`), as the other fetch leaves write them, so they replay from the archive. "
            + "A's are the import child's records, whose argv names a staged FASTQ the run deleted. The records of "
            + "provenance/ carry the leaf's run on C, with its argv, command, options, steps and the files they name, and "
            + "the import child's run on A, so each field of a run differs, its tool and workflow names, its id and its "
            + "primary output among them (BIO ruling on lane A45 M3c, section c item 2)."
        let root = "differs: <ANY>.lungfishfastq/.lungfish-provenance.json at "
        let perOutput = "differs: <ANY>.lungfishfastq/provenance/<ANY>lungfish-provenance.json at "
        let closedBy = closer
        func entry(
            _ prefix: String, _ suffix: String, _ toolkit: Int, _ mirror: Int, _ reason: String
        ) -> RouteParityDeclaredDifference<Case> {
            RouteParityDeclaredDifference(
                [Case.toolkitRun: toolkit, Case.enaMirrorRun: mirror].filter { $0.value > 0 },
                prefix + suffix, reason: reason, closedBy: closedBy)
        }
        return [
            entry(root, "argv[<ANY>", 15, 15, command),
            entry(root, "reproducibleCommand", 1, 1, command),
            entry(root, "options.explicit.cliCommand.<ANY>", 1, 1, command),
            entry(root, "steps[<ANY>].argv[<ANY>", 12, 6, command),
            entry(root, "steps[<ANY>].durableReplayArgv[<ANY>", 3, 2, command),
            entry(root, "steps[<ANY>].reproducibleCommand", 5, 3, command),
            entry(root, "options.explicit.stagingInputs.<ANY>", 1, 1, staging),
            entry(root, "outputs[<ANY>", 2, 1, staging),
            entry(root, "steps[<ANY>].inputs[<ANY>].path", 4, 2, staging),
            entry(root, "steps[<ANY>].outputs[<ANY>].path", 2, 1, staging),
            entry(root, "id", 1, 0, ids),
            entry(root, "options.explicit.preservedCLIProvenanceID.<ANY>", 1, 0, ids),
            entry(root, "steps[<ANY>].id", 1, 1, ids),
            entry(root, "files[<ANY>", 30, 12, files),
            entry(root, "steps[<ANY>].toolName", 1, 1, removal),
            entry(root, "steps[<ANY>].toolVersion", 1, 1, removal),
            entry(root, "steps[<ANY>].dependsOn", 1, 1, removal),
            entry(root, "steps[<ANY>].exitStatus", 1, 1, removal),
            entry(root, "steps[<ANY>].startedAt", 1, 1, removal),
            entry(root, "steps[<ANY>].completedAt", 1, 1, removal),
            entry(root, "steps[<ANY>].wallTimeSeconds", 1, 1, removal),
            entry(root, "steps[<ANY>].inputs[<ANY>].checksumSHA256", 1, 1, removal),
            entry(root, "steps[<ANY>].inputs[<ANY>].fileSize", 1, 1, removal),
            entry(root, "steps[<ANY>].inputs[<ANY>].role", 1, 1, removal),
            entry(root, "steps[<ANY>].outputs", 1, 1, removal),
            entry(root, "steps[<ANY>].resolvedOptions.<ANY>", 4, 4, removal),
            entry(perOutput, "argv[<ANY>", 54, 54, focused),
            entry(perOutput, "durableReplayArgv[<ANY>", 57, 57, focused),
            entry(perOutput, "files[<ANY>", 32, 24, focused),
            entry(perOutput, "id", 3, 3, focused),
            entry(perOutput, "options.<ANY>", 534, 525, focused),
            entry(perOutput, "output.<ANY>", 2, 2, focused),
            entry(perOutput, "reproducibleCommand", 3, 3, focused),
            entry(perOutput, "steps[<ANY>", 373, 285, focused),
            entry(perOutput, "tool.<ANY>", 6, 6, focused),
            entry(perOutput, "toolName", 3, 3, focused),
            entry(perOutput, "toolVersion", 3, 3, focused),
            entry(perOutput, "workflowName", 3, 3, focused),
        ]
    }()

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
        let legacy = makeTestDefaultsSuite(prefix: "DatabaseBrowserSRARowParityReplayTests")
        legacy.defaults.set(SRARowDownloadRoute.legacy.rawValue, forKey: SRARowDownloadRouteSettings.defaultsKey)
        let viaCLI = makeTestDefaultsSuite(prefix: "DatabaseBrowserSRARowParityReplayTests")
        viaCLI.defaults.set(SRARowDownloadRoute.cli.rawValue, forKey: SRARowDownloadRouteSettings.defaultsKey)

        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(180))
        let runs = try await harness.run(
            in: root.appendingPathComponent("case", isDirectory: true),
            fixture: DatabaseBrowserNucleotideRowParityReplayTests.makeProject,
            sideA: { await Self.row(in: $0, suite: legacy.name) },
            sideC: { await Self.row(in: $0, suite: viaCLI.name) }
        )
        let result = try harness.evaluate(parityCase, declared: Self.declared, runs: runs)
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
            // B-5 over every record of the bundle, on the CLI route's two sides. Side A keeps the digest the import
            // child stated for the metadata sidecar in its records, because the window rewrites the sidecar after the
            // child exits (`DatabaseBrowserViewModel+SRAWindowDownload.swift:248-255`) and never states it again.
            // That route is reached only through the hidden key's `legacy` value after the flip, and 2.11 deletes it
            // with the key (C4), so the stale digest stays until then (BIO ruling on lane A45 M3c, section b item 3).
            if run.side != .a {
                try FetchSRAFetchedRecordReplayTests.assertEveryRecordNamesItsFilesInTheBundle(
                    bundle, side: "side \(run.side)")
            }
        }
    }

    // MARK: - Sides

    /// One SRA run of the browser's download into the project of `root`, by the route `suite` names, and
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
