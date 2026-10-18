// VCFImportCLIGUIParityReplayTests.swift - The Import Center's VCF import in process against import vcf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.07 (A64) M2, ARCH 2, X14, on lane Q30's harness. The Import Center attaches a VCF to a reference
// bundle in one of three modes, a fresh import, `--resume` of a replaced track whose import stopped before its index
// build, and `--materialize` of a replaced track whose INFO table stopped. Each case runs on three sides that start as
// copies of one project.
//
// - Side A is the cores the helper's modes ran, in process, `VCFBundleVariantImport.attachInProcess` for a fresh
//   import and `VariantDatabase.resumeImport` or `materializeVariantInfo` on a private copy for the two modes, through
//   `ImportCommand.VCFSubcommand.attach`, with the command the leaf records.
// - Side C is the app's route, the mode `VCFImportCLICommand.mode` reads from the track's database and the argv of
//   `VCFImportCLICommand.arguments` on `CLIBundleBuildRunner`, which launches the built `lungfish-cli import vcf`.
//   Its row records the command.
// - Side C' is the harness's replay of that command.
//
// A against C declares nothing (ruling ARCH-12.07-partition, option (a)). The fixture takes one pass on both routes.
// The cancel cases cancel C and C' through the real transport with every core busy.
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class VCFImportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable, CaseIterable {
        case fresh
        case resume
        case materialize

        var mode: VCFImportCLICommand.Mode { VCFImportCLICommand.Mode(rawValue: rawValue)! }
        var attachMode: ImportCommand.VCFSubcommand.AttachMode { .init(rawValue: rawValue)! }
        var replaceTrackID: String? { self == .fresh ? nil : "test" }
    }

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "vcf-import-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(300))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testAFreshImportAttachesWhatTheCoreAttached() async throws {
        try await assertParity(.fresh)
    }

    func testAResumeFinishesTheTrackAsTheCoreFinishedIt() async throws {
        try await assertParity(.resume)
    }

    func testAMaterializeFillsTheTrackAsTheCoreFilledIt() async throws {
        try await assertParity(.materialize)
    }

    func testACancelledFreshImportEndsCancelledWithEveryCoreBusy() async throws {
        try await assertCancelledWithEveryCoreBusy(.fresh)
    }

    func testACancelledResumeEndsCancelledWithEveryCoreBusy() async throws {
        try await assertCancelledWithEveryCoreBusy(.resume)
    }

    func testACancelledMaterializeEndsCancelledWithEveryCoreBusy() async throws {
        try await assertCancelledWithEveryCoreBusy(.materialize)
    }

    // MARK: - The cases

    private func assertParity(_ parityCase: Case, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await harness.assertParity(
            parityCase,
            declared: [],
            in: scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: { root in try Self.writeFixture(root, for: parityCase, records: nil) },
            sideA: { root in await self.sideA(root, parityCase) },
            sideC: { root in await self.sideC(root, parityCase) },
            file: file, line: line
        )
        for run in result.runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "\(run.side): \(run.outcome.detail)", file: file, line: line)
            let (_, bundle, _) = Self.paths(run.root)
            let commands = try VCFImportModesPinTests.recordedCommands(in: bundle)
            XCTAssertEqual(commands.count, 1, "side \(run.side) records one step: \(commands)", file: file, line: line)
            XCTAssertEqual(Array(commands.first?.prefix(3) ?? []), ["lungfish-cli", "import", "vcf"], file: file, line: line)
            XCTAssertFalse(commands.joined().joined().contains("-helper"), "side \(run.side): \(commands)", file: file, line: line)
        }
        XCTAssertEqual(result.runs.a.outcome.detail, result.runs.c.outcome.detail, "the row's complete words", file: file, line: line)
        XCTAssertEqual(result.runs.c.outcome.detail, "9 variants imported", file: file, line: line)
    }

    /// Sides C and C' are cancelled through the real transport once the command made its private staging folder, while
    /// one busy thread spins on every core. Each exits 125 inside the grace with its record cancelled and no process of
    /// its tree left (`assertCancelled`), ends Cancelled, which raises no alert, and adds no track. Side A is not run,
    /// since the in-process core has no transport to cancel.
    private func assertCancelledWithEveryCoreBusy(_ parityCase: Case, file: StaticString = #filePath, line: UInt = #line) async throws {
        let load = BusyCores()
        load.start()
        defer { load.stop() }
        let busy = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            load.spinningCount == load.threadCount
        }
        XCTAssertTrue(busy, "\(load.spinningCount) of \(load.threadCount) busy threads spin", file: file, line: line)

        let cancel = RouteParityCancel(
            when: { root in !Self.stagingFolders(in: Self.paths(root).bundle).isEmpty },
            record: { root in ProvenanceRecorder.loadEnvelope(from: Self.paths(root).project)?.status.rawValue }
        )
        let cli = harness.cliBinary
        let runs = try await harness.run(
            in: scratch.appendingPathComponent("cancel-\(parityCase.rawValue)", isDirectory: true),
            cancel: cancel,
            fixture: { root in try Self.writeFixture(root, for: parityCase, records: 400_000) },
            sideA: { _ in RouteParitySideOutcome(end: .cancelled, detail: "not run, the in-process core has no transport") },
            sideC: { root in
                let (vcf, bundle, _) = Self.paths(root)
                let mode = VCFImportCLICommand.mode(forTrackID: "test", replacing: parityCase.replaceTrackID, in: bundle)
                let run = await RouteParityHarness.runCLI(
                    cli,
                    arguments: VCFImportCLICommand.arguments(
                        vcfURL: vcf, bundleURL: bundle, importProfile: .auto,
                        replaceTrackID: parityCase.replaceTrackID, mode: mode
                    ),
                    timeout: .seconds(120),
                    cancelWhen: { cancel.isReached(root) }
                )
                return RouteParitySideOutcome(
                    end: run.end,
                    detail: run.detail,
                    recordedCommand: VCFImportCLICommand.build(
                        vcfURL: vcf, bundleURL: bundle, importProfile: .auto,
                        replaceTrackID: parityCase.replaceTrackID, mode: mode
                    ),
                    cancel: run.cancel
                )
            }
        )
        for side in [runs.c, runs.cPrime] {
            XCTAssertEqual(side.outcome.end, .cancelled, "\(side.side): \(side.outcome.detail)", file: file, line: line)
            await RouteParityHarness.assertCancelled(side, cancel, file: file, line: line)
            let bundle = Self.paths(side.root).bundle
            XCTAssertEqual(Self.stagingFolders(in: bundle), [], "side \(side.side) removes its staging folder", file: file, line: line)
            XCTAssertEqual(
                try BundleManifest.load(from: bundle).variants.map(\.id), parityCase == .fresh ? [] : ["test"],
                "side \(side.side): a cancelled import adds no track", file: file, line: line
            )
        }
    }

    // MARK: - The sides

    /// Side A. The cores in process through the leaf's own attach, with the command the leaf records.
    private func sideA(_ root: URL, _ parityCase: Case) async -> RouteParitySideOutcome {
        let (vcf, bundle, _) = Self.paths(root)
        let request = VCFBundleVariantImport.Request(
            vcfURL: vcf, bundleURL: bundle, trackName: nil, importProfile: .auto, replaceTrackID: parityCase.replaceTrackID
        )
        let command = ["lungfish-cli"] + VCFImportCLICommand.arguments(
            vcfURL: vcf, bundleURL: bundle, importProfile: .auto,
            replaceTrackID: parityCase.replaceTrackID, mode: parityCase.mode
        ).dropLast(2)
        let clock = ProvenanceRunClock()
        do {
            let summary = try ImportCommand.VCFSubcommand.attach(
                request, mode: parityCase.attachMode, progressHandler: { _, _ in }, shouldCancel: { false }
            ) { facts in
                try ImportCommand.VCFSubcommand.vcfAttachProvenance(
                    facts: facts, mode: parityCase.attachMode, command: command, runClock: clock
                )
            }
            return RouteParitySideOutcome(end: .completed, detail: "\(summary.variantCount) variants imported")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// Side C. The mode the row reads from the track's database, the row the Import Center begins and the argv it runs
    /// on the runner that launches the built CLI. The row's command is the argv the runner runs (ARCH 2).
    private func sideC(_ root: URL, _ parityCase: Case) async -> RouteParitySideOutcome {
        let (vcf, bundle, _) = Self.paths(root)
        let mode = VCFImportCLICommand.mode(forTrackID: "test", replacing: parityCase.replaceTrackID, in: bundle)
        guard mode == parityCase.mode else {
            return RouteParitySideOutcome(end: .failed, detail: "the row chose \(mode) for \(parityCase)")
        }
        let arguments = VCFImportCLICommand.arguments(
            vcfURL: vcf, bundleURL: bundle, importProfile: .auto, replaceTrackID: parityCase.replaceTrackID, mode: mode
        )
        let reporter = RecordingOperationReporter()
        guard let operationID = AppDelegate.beginVCFImportOperation(
            vcfURL: vcf, bundleURL: bundle, importProfile: .auto, replaceTrackID: parityCase.replaceTrackID, mode: mode,
            routeContext: nil, reporter: reporter, onCancel: {}, launch: { _ in }
        ).startedID else {
            return RouteParitySideOutcome(end: .failed, detail: "the row was refused")
        }
        let command = reporter.items.first?.cliCommand
        guard command == OperationCenter.buildCLICommand(subcommand: "import vcf", args: Array(arguments.dropFirst(2))) else {
            return RouteParitySideOutcome(end: .failed, detail: "the row records \(command ?? "nothing"), not the argv it runs")
        }
        do {
            let result = try await CLIBundleBuildRunner(cliURLOverride: harness.cliBinary).run(
                arguments: arguments, operationID: operationID
            )
            return RouteParitySideOutcome(end: .completed, detail: result.message ?? "", recordedCommand: command)
        } catch is CancellationError {
            return RouteParitySideOutcome(end: .cancelled, detail: "cancelled", recordedCommand: command)
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: command)
        }
    }

    // MARK: - Fixture

    /// The VCF in the project's `Incoming` folder, the bundle and the project.
    nonisolated private static func paths(_ root: URL) -> (vcf: URL, bundle: URL, project: URL) {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let compressed = project.appendingPathComponent("Incoming/test.vcf.gz")
        return (
            FileManager.default.fileExists(atPath: compressed.path)
                ? compressed : project.appendingPathComponent("Incoming/test.vcf"),
            project.appendingPathComponent("Reference.lungfishref", isDirectory: true),
            project
        )
    }

    /// A project with a reference bundle and the VCF in its `Incoming` folder, the sarscov2 fixture (`test.vcf.gz`) or,
    /// with `records`, a plain VCF that long, so the path masks to the project in every record. For `resume` the bundle
    /// holds the track `test` whose database stopped at `indexing`, as an ultra-low-memory import leaves it, and for
    /// `materialize` the same track finished with its materialization stopped.
    nonisolated private static func writeFixture(_ root: URL, for parityCase: Case, records: Int?) throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = project.appendingPathComponent("Reference.lungfishref", isDirectory: true)
        let incoming = project.appendingPathComponent("Incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let vcf: URL
        if let records {
            vcf = incoming.appendingPathComponent("test.vcf")
            try largeVCF(records: records).write(to: vcf, atomically: true, encoding: .utf8)
        } else {
            vcf = incoming.appendingPathComponent("test.vcf.gz")
            let source = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/sarscov2/test.vcf.gz")
            try FileManager.default.copyItem(at: source, to: vcf)
        }
        var manifest = BundleManifest(
            name: "Reference",
            identifier: "bundle.reference",
            source: SourceInfo(organism: "Virus", assembly: "MT192765.1", database: "Test")
        )
        if parityCase != .fresh {
            let database = bundle.appendingPathComponent("variants/test.db")
            try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
            let count = try VCFBundleVariantImport.createDatabase(
                vcfURL: vcf, outputDBURL: database, sourceFile: vcf.lastPathComponent, importProfile: .ultraLowMemory
            )
            if parityCase == .materialize {
                _ = try VariantDatabase.resumeImport(existingDBURL: database)
                try VariantDatabase(url: database, readWrite: true).setMetadataValues(["materialize_state": "materializing"])
            }
            manifest = manifest.replacingVariantTrack(
                VCFBundleVariantImport.makeTrackInfo(trackID: "test", vcfURL: vcf, variantCount: count)
            )
        }
        try manifest.save(to: bundle)
    }

    /// A VCF of `records` single-base variants on MT192765.1, each with INFO fields, so an import runs for seconds.
    nonisolated private static func largeVCF(records: Int) -> String {
        var text = "##fileformat=VCFv4.2\n##contig=<ID=MT192765.1,length=29829>\n"
            + "##INFO=<ID=DP,Number=1,Type=Integer,Description=\"Depth\">\n"
            + "##INFO=<ID=AF,Number=A,Type=Float,Description=\"Allele frequency\">\n"
            + "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n"
        text.reserveCapacity(records * 48)
        let bases = ["A", "C", "G", "T"]
        for index in 0..<records {
            let position = index * 29_000 / records + 1
            text += "MT192765.1\t\(position)\t.\t\(bases[index % 4])\t\(bases[(index + 1) % 4])\t60\tPASS\tDP=\(index % 500);AF=0.5\n"
        }
        return text
    }

    nonisolated private static func stagingFolders(in bundle: URL) -> [String] {
        let variants = bundle.appendingPathComponent("variants", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: variants.path)) ?? []).filter { $0.hasPrefix(".import-") }
    }
}
