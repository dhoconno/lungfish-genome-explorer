// ONTImportCLIGUIParityReplayTests.swift - The ONT import on the CLI route against the in-process route it replaced
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A53 M3 (panel decisions G1, C4, C5 and C11, ARCH 2, 3 and 7, BIO 1 and 2, UX 1, 3 and 4,
// ruling A53-M3). The window's ONT import runs `lungfish-cli fastq import-ont --format json` on the L6
// runner. The parity class runs one import of the shared three-barcode run folder (ONTImportFreezeFixture)
// on the three sides of RouteParityHarness.
//
// - Side A, the in-process route as ONTImportOperationCoordinator ran it before the move: begin the row,
//   run ONTImportWorkflow in this process with the context the coordinator built (caller `gui`), and
//   complete the row. The test holds its own copy, since the app no longer has the route.
// - Side C, the CLI route, ONTImportOperationCoordinator on the built command.
// - Side C', the command side C's row recorded, rebased and run by the built CLI.
//
// BIO 1 reads the reads of each barcode from each side's manifest. The `caller` is the route's identity
// and the contract masks it (ruling A53-M3), and both routes record `LungfishAppVersion.short`, so the
// only difference A against C declares is the one BIO's ruling D8 on lane A46 gave the other L6 leaves.
// The record names its row's command, and the in-process row recorded the command without the
// `--format json` that only the CLI route runs with. C against C' declares nothing. UX 1 and 3 compare
// the rows of sides A and C: the same stage words in the same order and the same end, with a bar that
// only rises. The failure case shows the words of a failed import on both routes.
//
// It launches the built lungfish-cli, so its name ends in ReplayTests and it runs in the integration tier.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class ONTImportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case chunkedRun
        case flattenedRun
    }

    nonisolated private static let concurrency = 1
    nonisolated private static let title = "ONT Import: fastq_pass"

    private var scratch: URL!
    private var cliBinary: URL!
    private var harness: RouteParityHarness!

    override func setUp() async throws {
        try await super.setUp()
        // A failed row writes its report, which stays out of the user's ~/Library/Logs.
        OperationCenter.useTemporaryFailureReportsForTesting()
        scratch = try TestTempDirectory.make(prefix: "ont-import-parity")
        cliBinary = try ONTImportFreezeFixture.builtCLI(for: Self.self)
        harness = RouteParityHarness(cliBinary: cliBinary, kind: .bundle, replayTimeout: .seconds(120))
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    // MARK: - A against C, C against C'

    func testTheChunkedImportAgreesOnBothRoutes() async throws {
        try await assertParity(.chunkedRun, storageMode: .chunked)
    }

    func testTheFlattenedImportAgreesOnBothRoutes() async throws {
        try await assertParity(.flattenedRun, storageMode: .flattened)
    }

    /// BIO's ruling D8 on lane A46, for this leaf. The record of each run, the run folder's and each
    /// bundle's, names its row's command, and the in-process row recorded the command without
    /// `--format json`. The pair is two entries at the end of each argv list and the words at the end of
    /// each command line, in the record and in its step. A chunked import writes 20 records and a
    /// flattened one 13, the run folder's, each bundle's and one for each file a bundle keeps.
    private static let declared: [RouteParityDeclaredDifference<Case>] = {
        let reason = "the in-process row recorded fastq import-ont without --format json, and the record names its row's command"
        func entry(_ id: String, chunked: Int, flattened: Int) -> RouteParityDeclaredDifference<Case> {
            RouteParityDeclaredDifference(
                [.chunkedRun: chunked, .flattenedRun: flattened], "differs: <ANY>.lungfish-provenance.json at \(id)",
                reason: reason, closedBy: "2.11"
            )
        }
        return [
            entry("argv[<ANY>]", chunked: 40, flattened: 26),
            entry("durableReplayArgv[<ANY>]", chunked: 40, flattened: 26),
            entry("reproducibleCommand", chunked: 20, flattened: 13),
            entry("steps[<ANY>].argv[<ANY>]", chunked: 40, flattened: 26),
            entry("steps[<ANY>].durableReplayArgv[<ANY>]", chunked: 40, flattened: 26),
            entry("steps[<ANY>].reproducibleCommand", chunked: 20, flattened: 13),
        ]
    }()

    private func assertParity(_ parityCase: Case, storageMode: ONTImportStorageMode) async throws {
        var rows: [RouteParitySide: MappingRouteRow] = [:]
        let runs = try await harness.run(
            in: scratch.appendingPathComponent("parity-\(parityCase.rawValue)", isDirectory: true),
            fixture: Self.writeFixture,
            sideA: { root in
                let (row, item) = try await ReadsRouteParity.record(title: Self.title) {
                    Self.startInProcess(root, storageMode: storageMode)
                }
                rows[.a] = ReadsRouteParity.rooted(row, root)
                return ReadsRouteParity.outcome(of: item)
            },
            sideC: { root in
                let coordinator = ONTImportOperationCoordinator(
                    operationCenter: OperationCenter.shared, runner: CLIReadsRunner(cliURLOverride: self.cliBinary)
                )
                let (row, item) = try await ReadsRouteParity.record(title: Self.title) {
                    Task { @MainActor in
                        _ = try? await coordinator.importDirectory(
                            sourceURL: Self.source(in: root), projectURL: Self.project(in: root), includeUnclassified: true,
                            concurrency: Self.concurrency, storageMode: storageMode, routeContext: nil
                        )
                    }
                }
                rows[.c] = ReadsRouteParity.rooted(row, root)
                return ReadsRouteParity.outcome(of: item, recordsCommand: true)
            }
        )

        XCTAssertEqual(runs.all.map(\.outcome.end), [.completed, .completed, .completed], runs.all.map(\.outcome.detail).joined(separator: "\n"))
        let result = try harness.evaluate(parityCase, declared: Self.declared, runs: runs)
        RouteParityHarness.assertNoFailures(result.failures, in: "\(parityCase)")

        // BIO 1 and 2, equal reads per barcode on every side, from each side's own manifest.
        let expected = ONTImportFreezeFixture.readsPerBarcode.map { "\($0.barcode)=\($0.reads)" }
        for run in runs.all {
            let folder = Self.project(in: run.root).appendingPathComponent("Imports/Run1", isDirectory: true)
            let manifest = try XCTUnwrap(DemultiplexManifest.load(from: folder), "side \(run.side) wrote no manifest")
            XCTAssertEqual(manifest.barcodes.map { "\($0.barcodeID)=\($0.readCount)" }, expected, "side \(run.side), reads per barcode")
        }

        // The command side C recorded is the argv its runner launched, ARCH 2.
        let command = try XCTUnwrap(runs.c.outcome.recordedCommand)
        XCTAssertTrue(command.hasSuffix(" --format json"), command)

        // UX 1 and 3, the CLI route's row shows the in-process row's words, in its order, ends the same
        // way, and its bar only rises. The closing stage word names the seconds it took, which no two
        // runs share.
        let rowA = try XCTUnwrap(rows[.a])
        let rowC = try XCTUnwrap(rows[.c])
        XCTAssertEqual(Self.untimed(rowC.shown), Self.untimed(rowA.shown), "the CLI route's row shows the in-process row's words")
        XCTAssertEqual(rowC.end, rowA.end, "the CLI route's row ends as the in-process row ends")
        XCTAssertEqual(rowC.bar, MappingRouteRow.heldBar(rowA.bar), "the CLI route's bar is the in-process bar, held")
        XCTAssertEqual(rowC.bar, MappingRouteRow.heldBar(rowC.bar), "the CLI route's bar only rises")
        // The last detail is the end of the row, which is not a stage word and is not logged.
        for word in rowC.shown.dropLast() where !word.isEmpty {
            XCTAssertTrue(rowC.logged.contains("info \(word)"), "the CLI route's log keeps the stage word \(word)")
        }
    }

    // MARK: - A failed import (W3)

    /// A chunk the import cannot read fails it on either route. The sheet keeps the words of the failure
    /// (decision W3), so the CLI route must give the words the in-process row gave, which the command
    /// forwards in its `failed` line.
    func testAFailedImportGivesTheSameWordsOnBothRoutes() async throws {
        let rootA = scratch.appendingPathComponent("failure-A", isDirectory: true)
        let rootC = scratch.appendingPathComponent("failure-C", isDirectory: true)
        var unreadable: [URL] = []
        for root in [rootA, rootC] {
            try Self.writeFixture(root)
            let chunk = Self.source(in: root).appendingPathComponent("barcode01/chunk_1.fastq")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: chunk.path)
            unreadable.append(chunk)
        }
        defer {
            for chunk in unreadable { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: chunk.path) }
        }

        let (_, itemA) = try await ReadsRouteParity.record(title: Self.title) { Self.startInProcess(rootA, storageMode: .chunked) }
        let coordinator = ONTImportOperationCoordinator(
            operationCenter: OperationCenter.shared, runner: CLIReadsRunner(cliURLOverride: cliBinary)
        )
        let (_, itemC) = try await ReadsRouteParity.record(title: Self.title) {
            Task { @MainActor in
                _ = try? await coordinator.importDirectory(
                    sourceURL: Self.source(in: rootC), projectURL: Self.project(in: rootC), includeUnclassified: true,
                    concurrency: Self.concurrency, routeContext: nil
                )
            }
        }

        XCTAssertEqual(itemA.state, .failed, itemA.detail)
        XCTAssertEqual(itemC.state, .failed, itemC.detail)
        XCTAssertFalse(itemC.detail.isEmpty)
        XCTAssertEqual(
            Self.withoutRootOrAddress(itemC.detail, root: rootC), Self.withoutRootOrAddress(itemA.detail, root: rootA),
            "both routes fail with the words of the import error"
        )
        XCTAssertEqual(itemC.bundleURLs, [], "a failed import lists nothing")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: Self.project(in: rootC).appendingPathComponent("Imports/Run1/barcode01.lungfishfastq").path
            ),
            "the command left no partial bundle"
        )
    }

    // MARK: - Fixture, sides and helpers

    nonisolated static func source(in root: URL) -> URL {
        root.appendingPathComponent("Run1/fastq_pass", isDirectory: true)
    }

    nonisolated static func project(in root: URL) -> URL {
        root.appendingPathComponent("project", isDirectory: true)
    }

    /// The shared run folder under `<root>/Run1`, so every side names its run folder `Run1`.
    nonisolated static func writeFixture(_ root: URL) throws {
        _ = try ONTImportFreezeFixture.makeSource(in: root.appendingPathComponent("Run1", isDirectory: true))
    }

    /// `words` with the seconds of the closing stage word hidden.
    static func untimed(_ words: [String]) -> [String] {
        words.map { $0.replacingOccurrences(of: #", [0-9.]+s\)"#, with: ", <T>s)", options: .regularExpression) }
    }

    /// An error text with the side's root, the addresses of the objects it prints and the UUID of the
    /// import's staging folder hidden.
    static func withoutRootOrAddress(_ text: String, root: URL) -> String {
        [root.resolvingSymlinksInPath().path, root.path].reduce(text) { $0.replacingOccurrences(of: $1, with: "<ROOT>") }
            .replacingOccurrences(of: #"0x[0-9a-f]+"#, with: "<ADDRESS>", options: .regularExpression)
            .replacingOccurrences(
                of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, with: "<UUID>", options: .regularExpression
            )
    }

    /// Side A. The row and the run the coordinator made when the import ran in the app: begin the row with
    /// the command that reproduces the run, run the workflow in this process, report each stage word as
    /// it comes and complete the row.
    static func startInProcess(_ root: URL, storageMode: ONTImportStorageMode) {
        let sourceURL = source(in: root)
        let reporter: any OperationReporting = OperationCenter.shared
        do {
            let outputURL = try ONTImportOperationCoordinator.resolvedOutputDirectory(
                sourceURL: sourceURL, projectURL: project(in: root), includeUnclassified: true
            )
            let cliArgs = ONTImportOperationCoordinator.cliArgs(
                sourceURL: sourceURL, outputURL: outputURL, includeUnclassified: true,
                concurrency: concurrency, storageMode: storageMode
            )
            let cliCommand = OperationCenter.buildCLICommand(subcommand: "fastq import-ont", args: cliArgs)
            let opID = try reporter.begin(
                title: "ONT Import: \(sourceURL.lastPathComponent)", detail: "Detecting layout...",
                operationType: .ingestion, cliCommand: cliCommand, routeContext: nil
            ).requireStarted()
            Task { @MainActor in
                do {
                    let result = try await ONTImportWorkflow().importDirectory(
                        config: ONTImportConfig(
                            sourceDirectory: sourceURL, outputDirectory: outputURL, maxConcurrentBarcodes: concurrency,
                            includeUnclassified: true, storageMode: storageMode
                        ),
                        context: inProcessContext(
                            sourceURL: sourceURL, outputURL: outputURL, storageMode: storageMode, cliArgs: cliArgs, cliCommand: cliCommand
                        ),
                        optimization: ONTImportWorkflow.OptimizationConfig(optimizeStorage: false, qualityBinning: .none, threads: concurrency)
                    ) { fraction, message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { _ = reporter.update(id: opID, progress: fraction, detail: message) }
                        }
                    }
                    // The stage words reach the row through the main queue. The last of them lands before the end.
                    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                    let imported = result.importResult
                    _ = reporter.complete(
                        id: opID, detail: "\(imported.bundleURLs.count) barcode bundles, \(imported.totalReadCount) reads",
                        bundleURLs: imported.bundleURLs
                    )
                } catch {
                    _ = reporter.fail(
                        id: opID, detail: error.localizedDescription, errorMessage: error.localizedDescription, errorDetail: "\(error)"
                    )
                }
            }
        } catch {
            XCTFail("side A could not begin: \(error)")
        }
    }

    /// The context the coordinator gave the workflow before the move. The caller is `gui`, which the
    /// contract masks, and the version is the release version both routes record (ruling A53-M3).
    nonisolated static func inProcessContext(
        sourceURL: URL,
        outputURL: URL,
        storageMode: ONTImportStorageMode,
        cliArgs: [String],
        cliCommand: String
    ) -> ONTImportWorkflow.CommandContext {
        let argv = [CLICommandIdentity.executableName, "fastq", "import-ont"] + cliArgs
        return ONTImportWorkflow.CommandContext(
            caller: .gui,
            workflowName: "lungfish fastq import-ont",
            workflowVersion: LungfishAppVersion.short,
            toolName: "lungfish fastq import-ont",
            toolVersion: LungfishAppVersion.short,
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: cliCommand,
            explicitOptions: [
                "input": .file(sourceURL),
                "output": .file(outputURL),
                "includeUnclassified": .boolean(true),
                "concurrency": .integer(concurrency),
                "storageMode": .string(storageMode.rawValue),
                "optimizeStorage": .boolean(false),
                "qualityBinning": .string(QualityBinningScheme.none.rawValue),
            ],
            defaultOptions: [
                "includeUnclassified": .boolean(false),
                "concurrency": .integer(4),
                "storageMode": .string(ONTImportStorageMode.chunked.rawValue),
                "optimizeStorage": .boolean(false),
                "qualityBinning": .string(QualityBinningScheme.none.rawValue),
                "useVirtualConcatenation": .boolean(true),
            ],
            resolvedOptions: [
                "input": .file(sourceURL),
                "output": .file(outputURL),
                "includeUnclassified": .boolean(true),
                "concurrency": .integer(concurrency),
                "storageMode": .string(storageMode.rawValue),
                "optimizeStorage": .boolean(false),
                "qualityBinning": .string(QualityBinningScheme.none.rawValue),
                "useVirtualConcatenation": .boolean(storageMode.usesVirtualConcatenation),
                "caller": .string("gui"),
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity(appVersion: LungfishAppVersion.short)
        )
    }
}
