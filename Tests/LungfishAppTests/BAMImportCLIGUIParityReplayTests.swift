// BAMImportCLIGUIParityReplayTests.swift - The Import Center's BAM import in the helper against import bam
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A63 M1 (K4 p12), plan decisions C4, C5 and C12 on lane Q30's harness. The Import Center attaches
// a BAM to a reference bundle. Each case runs on three sides that start as copies of one project.
//
// - Side A is the helper's call in process, `BAMImportService.importBAM(bamURL:bundleURL:name:)` with the file's
//   name, which the app ran in `--bam-import-helper` mode before the route moved.
// - Side C is the app's route, `BAMImportCLICommand.arguments` on `CLIBundleBuildRunner`, which launches the built
//   `lungfish-cli import bam`. Its row records the command.
// - Side C' is the harness's replay of that command.
//
// A against C declares the one thing that has to differ, the command the import record names (the helper flag
// against `lungfish-cli import bam`). C against C' declares nothing (C4).
//
// It runs the managed samtools and launches the built lungfish-cli, so its name ends in ReplayTests, which sends it
// to the integration tier, and it skips without samtools unless `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class BAMImportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case sortedBAM
    }

    /// The record of the import, which the service writes in the bundle.
    private static let record = "Project.lungfish/Reference.lungfishref/alignments/<RUN-ID-1>.import.lungfish-provenance.json"
    private static let commandReason = "The record names the command that ran. The helper's is `<app> --bam-import-helper --bam-path <bam> --bundle-path <bundle> --name <name>`, which lungfish-cli cannot run, and the leaf's is `lungfish-cli import bam <bam> --output-dir <bundle> --name <name>`."
    private static let commandClosedBy = "A63 M3, which deletes the helper"

    /// The differences of A against C, all in the command the record names.
    static let declared: [RouteParityDeclaredDifference<Case>] = [
        RouteParityDeclaredDifference([.sortedBAM: 4], "differs: \(record) at argv[<ANY>]", reason: commandReason, closedBy: commandClosedBy),
        RouteParityDeclaredDifference([.sortedBAM: 4], "differs: \(record) at durableReplayArgv[<ANY>]", reason: commandReason, closedBy: commandClosedBy),
        RouteParityDeclaredDifference([.sortedBAM: 4], "differs: \(record) at steps[2].argv[<ANY>]", reason: commandReason, closedBy: commandClosedBy),
        RouteParityDeclaredDifference([.sortedBAM: 1], "differs: \(record) at reproducibleCommand", reason: commandReason, closedBy: commandClosedBy),
        RouteParityDeclaredDifference([.sortedBAM: 1], "differs: \(record) at steps[2].reproducibleCommand", reason: commandReason, closedBy: commandClosedBy),
    ]

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "bam-import-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        // The import record that BAMImportService keeps in the bundle's stats.db ends in the run's duration in seconds,
        // which no two runs share, so the family masks that one value. This is the one mask this class adds to the
        // standard policy, and the contract's reviewer rules on it (lane A63 report).
        var masks = OutputEquivalence.MaskPolicy.standard
        masks.records.append(OutputEquivalence.Mask(name: "importBamDuration") { text, _ in
            text.replacingOccurrences(
                of: #"(\timport-bam\t[^\n]*\t)[0-9]+(?:\.[0-9]+)?(?=\t[^\t\n]*(?:\n|$))"#,
                with: "$1<DURATION>",
                options: .regularExpression
            )
        })
        harness = RouteParityHarness(cliBinary: cli, kind: .bundle, masks: masks, replayTimeout: .seconds(300))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testTheBAMRowAttachesWhatTheHelperAttached() async throws {
        try await requireSamtools()
        let result = try await harness.assertParity(
            Case.sortedBAM,
            declared: Self.declared,
            in: scratch.appendingPathComponent(Case.sortedBAM.rawValue, isDirectory: true),
            fixture: { root in try Self.writeFixture(root) },
            sideA: { root in await self.sideA(root) },
            sideC: { root in await self.sideC(root) }
        )
        for run in result.runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "\(run.side): \(run.outcome.detail)")
        }
        XCTAssertEqual(result.runs.a.outcome.detail, result.runs.c.outcome.detail, "the row's complete words")
        XCTAssertTrue(result.runs.c.outcome.detail.hasSuffix(" reads imported"), result.runs.c.outcome.detail)
        for run in result.runs.all {
            let (bam, bundle, _) = Self.paths(run.root)
            let manifest = try BundleManifest.load(from: bundle)
            XCTAssertEqual(manifest.alignments.map(\.name), [bam.lastPathComponent], "side \(run.side): one track named for the file")
            let commands = try Self.recordedCommands(in: bundle)
            if run.side == .a {
                XCTAssertTrue(commands.contains { $0.contains("--bam-import-helper") }, "side A records the helper flag: \(commands)")
            } else {
                XCTAssertTrue(commands.contains { $0.contains("lungfish-cli") && $0.contains("import") && $0.contains("bam") }, "side \(run.side) records the command: \(commands)")
                XCTAssertFalse(commands.contains { $0.contains("--bam-import-helper") }, "side \(run.side) records no helper flag: \(commands)")
            }
        }
    }

    /// Side C and its replay are cancelled through the real transport once a stand-in samtools holds the sort. Each exits 125
    /// inside the grace after the cancel, its record in the project reads cancelled and no process of its tree is left (lane S30's
    /// assertions in `assertCancelled`). The cancelled import adds nothing to the bundle. Side A is not run, since the in-process
    /// service has no cancel and writes no record.
    func testACancelWhileSortingEndsCancelledWithARecordAndNothingAddedOnTheCommandRoutes() async throws {
        let cancel = RouteParityCancel(
            when: { root in FileManager.default.fileExists(atPath: Self.standInPIDFile(in: root).path) },
            record: { root in ProvenanceRecorder.loadEnvelope(from: Self.paths(root).project)?.status.rawValue }
        )
        let cli = harness.cliBinary
        let standIn = RouteParityHarness(
            cliBinary: cli,
            kind: .bundle,
            replayTimeout: .seconds(120),
            environment: { root in ["LUNGFISH_CONDA_ROOT": root.appendingPathComponent("conda", isDirectory: true).path] }
        )
        let runs = try await standIn.run(
            in: scratch.appendingPathComponent("cancel", isDirectory: true),
            cancel: cancel,
            fixture: { root in try Self.writeCancelFixture(root) },
            sideA: { _ in RouteParitySideOutcome(end: .cancelled, detail: "not run, the in-process service has no cancel and writes no record") },
            sideC: { root in
                let (bam, bundle, _) = Self.paths(root)
                let run = await RouteParityHarness.runCLI(
                    cli,
                    arguments: BAMImportCLICommand.arguments(bamURL: bam, bundleURL: bundle),
                    timeout: .seconds(120),
                    environment: standIn.environment(root),
                    cancelWhen: { cancel.isReached(root) }
                )
                return RouteParitySideOutcome(
                    end: run.end,
                    detail: run.detail,
                    recordedCommand: BAMImportCLICommand.build(bamURL: bam, bundleURL: bundle),
                    cancel: run.cancel
                )
            }
        )
        for side in [runs.c, runs.cPrime] {
            XCTAssertEqual(side.outcome.end, .cancelled, "\(side.side): \(side.outcome.detail)")
            await RouteParityHarness.assertCancelled(side, cancel)
            let alignments = Self.paths(side.root).bundle.appendingPathComponent("alignments", isDirectory: true)
            XCTAssertEqual(
                (try? FileManager.default.contentsOfDirectory(atPath: alignments.path)) ?? [], [],
                "side \(side.side): a cancelled import adds nothing to the bundle"
            )
        }
    }

    // MARK: - The sides

    nonisolated private static func paths(_ root: URL) -> (bam: URL, bundle: URL, project: URL) {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        return (
            project.appendingPathComponent("Incoming/test.paired_end.sorted.bam"),
            project.appendingPathComponent("Reference.lungfishref", isDirectory: true),
            project
        )
    }

    /// Side A. The service in process, as the helper ran it before the route moved.
    private func sideA(_ root: URL) async -> RouteParitySideOutcome {
        let (bam, bundle, _) = Self.paths(root)
        do {
            let result = try await BAMImportService.importBAM(bamURL: bam, bundleURL: bundle, name: bam.lastPathComponent)
            return RouteParitySideOutcome(end: .completed, detail: "\(result.mappedReads + result.unmappedReads) reads imported")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// Side C. The row the Import Center begins and the argv it runs on the runner that launches the built CLI.
    private func sideC(_ root: URL) async -> RouteParitySideOutcome {
        let (bam, bundle, _) = Self.paths(root)
        let reporter = RecordingOperationReporter()
        guard let operationID = AppDelegate.beginBAMImportOperation(
            bamURL: bam, bundleURL: bundle, routeContext: nil, reporter: reporter, onCancel: {}, launch: { _ in }
        ).startedID else {
            return RouteParitySideOutcome(end: .failed, detail: "the row was refused")
        }
        let command = reporter.items.first?.cliCommand
        do {
            let result = try await CLIBundleBuildRunner(cliURLOverride: harness.cliBinary).run(
                arguments: BAMImportCLICommand.arguments(bamURL: bam, bundleURL: bundle),
                operationID: operationID
            )
            return RouteParitySideOutcome(end: .completed, detail: result.message ?? "", recordedCommand: command)
        } catch is CancellationError {
            return RouteParitySideOutcome(end: .cancelled, detail: "cancelled", recordedCommand: command)
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: command)
        }
    }

    // MARK: - Fixture

    /// A project with a reference bundle that holds no alignment, and the sarscov2 BAM in its `Incoming` folder, so the
    /// path of the input masks to the project in every record.
    private static func writeFixture(_ root: URL) throws {
        let (bam, bundle, _) = paths(root)
        try FileManager.default.createDirectory(at: bam.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sarscov2/test.paired_end.sorted.bam")
        try FileManager.default.copyItem(at: source, to: bam)
        try BundleManifest(
            name: "Reference",
            identifier: "bundle.reference",
            source: SourceInfo(organism: "Virus", assembly: "MN908947.3", database: "Test")
        ).save(to: bundle)
    }

    /// Where the stand-in samtools of a side writes its process ID.
    nonisolated private static func standInPIDFile(in root: URL) -> URL {
        root.appendingPathComponent("conda/envs/samtools/bin/samtools.pid")
    }

    /// The fixture of the cancel case, a project and a bundle as above, a BAM that only needs to exist and a conda root
    /// whose samtools answers a version probe and writes its process ID beside itself, then sleeps on any other call.
    private static func writeCancelFixture(_ root: URL) throws {
        let (bam, bundle, _) = paths(root)
        try FileManager.default.createDirectory(at: bam.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data([0x1f, 0x8b]).write(to: bam)
        try BundleManifest(
            name: "Reference",
            identifier: "bundle.reference",
            source: SourceInfo(organism: "Virus", assembly: "MN908947.3", database: "Test")
        ).save(to: bundle)
        let samtools = """
        #!/bin/sh
        case "$*" in
          *version*) echo "samtools 1.20"; exit 0 ;;
        esac
        echo $$ > "$(dirname "$0")/samtools.pid"
        exec sleep 120
        """
        let binary = root.appendingPathComponent("conda/envs/samtools/bin/samtools")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try samtools.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }

    /// The command of each step of the one import record in the bundle.
    private static func recordedCommands(in bundle: URL) throws -> [[String]] {
        let sidecars = try FileManager.default.subpathsOfDirectory(atPath: bundle.path)
            .filter { $0.hasSuffix(".json") && $0.lowercased().contains("provenance") }
        XCTAssertEqual(sidecars.count, 1, "one import record: \(sidecars)")
        let sidecar = bundle.appendingPathComponent(try XCTUnwrap(sidecars.first))
        let data = PortablePath.resolveJSON(try Data(contentsOf: sidecar), forFileAt: sidecar)
        return try ProvenanceEnvelopeReader.decodeCanonical(data).legacyWorkflowRun().steps.map(\.command)
    }

    private func requireSamtools(file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            _ = try await NativeToolRunner.shared.toolPath(for: .samtools)
        } catch {
            try ToolAvailability.skipOrFail("Managed samtools is required: \(error)", file: file, line: line)
        }
    }
}
