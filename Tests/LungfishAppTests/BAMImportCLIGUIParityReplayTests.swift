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

    // MARK: - The sides

    private static func paths(_ root: URL) -> (bam: URL, bundle: URL, project: URL) {
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
