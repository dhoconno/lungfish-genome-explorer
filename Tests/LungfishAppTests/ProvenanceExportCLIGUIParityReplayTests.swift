// ProvenanceExportCLIGUIParityReplayTests.swift - The provenance report export in the app against its CLI leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.38, ARCH ruling on the export shape 1.7, row B9, on lane Q30's harness. Each case runs on three
// sides that start as copies of one root that holds a folder with a provenance record.
//
// - Side A is the in-process write both entry points made at aea620334, frozen in ProvenanceExportFrozenWriter since
//   the lane deleted it from the app.
// - Side C is `AppDelegate.beginProvenanceExportOperation`, which begins the row and runs the built
//   `lungfish-cli provenance export` on `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded.
//
// A pinned record is exported in each of the six formats with no flag, and an unpinned record in each of the four
// script formats with `--allow-unpinned`, which is what Export Anyway… hands the command. A against C compares the
// folder's files under the harness masks. Every file is equal except the export's own record, and the record differs
// in its argv only (BIO 7, a prediction row of the lane report). The base's builder wrote `lungfish-cli` as the
// executable, and the leaf writes the path of the binary the app launched, in `argv[0]` and in the
// `reproducibleCommand` text it renders from argv. An override also differs in the place of `--allow-unpinned`, which
// follows `--export-format` in the row's command and followed `--output` in the builder. The tool, kind, workflow name,
// options and files of the record are the exporter's in both. C against C' compares everything under the contract's masks.

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class ProvenanceExportCLIGUIParityReplayTests: XCTestCase {
    struct Case: Hashable, Sendable, CustomStringConvertible {
        let format: ProvenanceExportFormat
        /// True when the record holds an unpinned step and the export carries Export Anyway…'s flag.
        let override: Bool

        var description: String { "\(format.cliToken)-\(override ? "override" : "pinned")" }
    }

    static let pinnedCases = ProvenanceExportFormat.allCases.map { Case(format: $0, override: false) }
    static let overrideCases = [ProvenanceExportFormat.shell, .python, .nextflow, .snakemake].map { Case(format: $0, override: true) }

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        scratch = try TestTempDirectory.make(prefix: "provenance-export-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .files, replayTimeout: .seconds(60))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testEveryFormatOfAPinnedRecordMatches() async throws {
        for parityCase in Self.pinnedCases {
            _ = try await assertParity(parityCase)
        }
    }

    func testTheOverrideOfAnUnpinnedRecordMatches() async throws {
        for parityCase in Self.overrideCases {
            _ = try await assertParity(parityCase)
        }
    }
}

// MARK: - The sides and the comparison

extension ProvenanceExportCLIGUIParityReplayTests {
    static func inputURL(in root: URL) -> URL {
        root.appendingPathComponent("input", isDirectory: true).standardizedFileURL
    }

    static func outputURL(in root: URL, _ parityCase: Case) -> URL {
        root.appendingPathComponent("out", isDirectory: true)
            .appendingPathComponent(parityCase.description, isDirectory: true).standardizedFileURL
    }

    static func exportRecord(in root: URL, _ parityCase: Case) throws -> ProvenanceEnvelope {
        let record = outputURL(in: root, parityCase).appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        return try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: record), "no export record at \(record.path)")
    }

    /// The root every side starts from, a folder with a record whose minimap2 step is unpinned or pinned. The
    /// pinned case records the version the tool lock holds.
    static func makeFixture(_ root: URL, override: Bool) throws {
        let input = inputURL(in: root)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let minimap2Version = override ? "unknown" : "2.31"
        let envelope = ProvenanceEnvelope(
            workflowName: "map",
            toolName: "minimap2",
            steps: [
                ProvenanceStep(
                    toolName: "minimap2",
                    toolVersion: "\(minimap2Version) (managed conda environment minimap2; executable minimap2)",
                    argv: ["minimap2", "-a", "ref.fa", "reads.fq"],
                    exitStatus: 0
                ),
                ProvenanceStep(
                    toolName: "samtools",
                    toolVersion: "1.24 (managed conda environment samtools; executable samtools)",
                    argv: ["samtools", "sort", "aln.sam"],
                    exitStatus: 0
                ),
            ],
            exitStatus: 0
        )
        try ProvenanceJSON.encoder.encode(envelope)
            .write(to: input.appendingPathComponent(ProvenanceRecorder.provenanceFilename), options: .atomic)
    }

    /// Side A. The in-process write, frozen.
    private func sideA(_ root: URL, _ parityCase: Case) async throws -> RouteParitySideOutcome {
        do {
            let bundle = try ProvenanceExportFrozenWriter.write(
                selectedURL: Self.inputURL(in: root),
                format: parityCase.format,
                outputDirectory: Self.outputURL(in: root, parityCase),
                allowUnpinned: parityCase.override
            )
            return RouteParitySideOutcome(end: .completed, detail: "Exported \(bundle.primaryArtifactURL.lastPathComponent)")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// Side C. The begin helper, which begins the row and runs the built CLI behind it on the shared runner.
    private func sideC(_ root: URL, _ parityCase: Case) async throws -> RouteParitySideOutcome {
        let invocation = ProvenanceReportExport.invocation(
            inputURL: Self.inputURL(in: root),
            format: parityCase.format,
            outputDirectory: Self.outputURL(in: root, parityCase),
            allowUnpinned: parityCase.override
        )
        let begun = try XCTUnwrap(AppDelegate.beginProvenanceExportOperation(
            invocation: invocation,
            format: parityCase.format,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary)
        ) { _ in })
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        switch outcome {
        case .completed:
            XCTAssertEqual(item?.state, .completed)
            return RouteParitySideOutcome(end: .completed, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .cancelled:
            return RouteParitySideOutcome(end: .cancelled, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .failed(let failure):
            return RouteParitySideOutcome(end: .failed, detail: failure.message, recordedCommand: item?.cliCommand)
        }
    }

    /// Runs the case on its three sides and checks it as 1.7 reads it. Each side completes with no side naming
    /// another's root, C against C' differs in nothing, and A against C is equal on the compared facts.
    @discardableResult
    private func assertParity(_ parityCase: Case) async throws -> RouteParityRuns {
        let runs = try await harness.run(
            in: scratch.appendingPathComponent(parityCase.description, isDirectory: true),
            fixture: { root in try Self.makeFixture(root, override: parityCase.override) },
            sideA: { root in try await self.sideA(root, parityCase) },
            sideC: { root in try await self.sideC(root, parityCase) }
        )
        if let dump = RouteParityHarness.dumpFolder {
            _ = try harness.evaluate(parityCase, declared: [], runs: runs, dumpingTo: dump)
        }
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "\(parityCase) side \(run.side): \(run.outcome.detail)")
        }
        let found = try harness.differences(of: runs)
        for side in RouteParitySide.allCases {
            XCTAssertEqual(found[.side(side)]?.map(\.description) ?? [], [], "\(parityCase) side \(side) names no other side's root")
        }
        XCTAssertEqual(found[.cAgainstCPrime]?.map(\.description) ?? [], [], "\(parityCase) C against C' declares nothing")
        try assertAEqualsC(runs, parityCase)
        return runs
    }

    /// A against C. The primary artifact is where the alert and the row link say, a pinned export is equal in every
    /// file, an override differs only in the export record's argv, and the record is equal in every other fact.
    private func assertAEqualsC(_ runs: RouteParityRuns, _ parityCase: Case) throws {
        let artifact = ProvenanceReportExport.primaryArtifactFileName(for: parityCase.format)
        for run in [runs.a, runs.c] {
            let path = Self.outputURL(in: run.root, parityCase).appendingPathComponent(artifact).path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "\(parityCase) side \(run.side) wrote \(artifact)")
        }
        let recordPath = "provenance/\(ProvenanceRecorder.provenanceFilename)"
        let differences = try harness.differences(runs.a, runs.c)
        XCTAssertEqual(
            differences.filter { !$0.id.contains(recordPath) }.map(\.description), [],
            "\(parityCase): only the export record may differ between A and C"
        )
        if !parityCase.override {
            let moved = differences.filter {
                $0.description.contains(" at argv[0]") || $0.description.contains(" at reproducibleCommand")
            }
            XCTAssertEqual(
                differences.map(\.description), moved.map(\.description),
                "\(parityCase): a pinned export differs only in the executable the record names"
            )
        }

        let a = try Self.exportRecord(in: runs.a.root, parityCase)
        let c = try Self.exportRecord(in: runs.c.root, parityCase)
        XCTAssertEqual(c.toolName, a.toolName, "\(parityCase) tool")
        XCTAssertEqual(c.tool.kind, a.tool.kind, "\(parityCase) tool kind")
        XCTAssertEqual(c.workflowName, a.workflowName, "\(parityCase) workflow name")
        XCTAssertEqual(c.durableReplayArgv == nil, a.durableReplayArgv == nil, "\(parityCase) durable replay argv")
        XCTAssertEqual(c.options.explicit.keys.sorted(), a.options.explicit.keys.sorted(), "\(parityCase) explicit options")
        XCTAssertEqual(c.options.resolvedDefaults.keys.sorted(), a.options.resolvedDefaults.keys.sorted(), "\(parityCase) resolved options")
        XCTAssertEqual(c.options.explicit["allowUnpinned"], a.options.explicit["allowUnpinned"], "\(parityCase) allowUnpinned")
        XCTAssertEqual(c.options.explicit["allowUnpinned"] == .boolean(true), parityCase.override, "\(parityCase) override")
        XCTAssertEqual(Self.files(of: c, under: runs.c.root), Self.files(of: a, under: runs.a.root), "\(parityCase) files")

        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(Array(rowArguments.prefix(2)), ProvenanceReportExport.commandPath)
        XCTAssertEqual(Array(c.argv.dropFirst()), rowArguments, "\(parityCase) the record's argv is the row's command")
        XCTAssertEqual(c.argv.first.map { URL(fileURLWithPath: $0).lastPathComponent }, CLICommandIdentity.executableName)
        XCTAssertEqual(a.argv.first, CLICommandIdentity.executableName)
        XCTAssertEqual(
            a.argv,
            ProvenanceExportFrozenWriter.argv(
                selectedURL: Self.inputURL(in: runs.a.root), format: parityCase.format,
                outputDirectory: Self.outputURL(in: runs.a.root, parityCase), allowUnpinned: parityCase.override
            ),
            "\(parityCase) side A recorded the base's argv"
        )
        let maskedA = Self.masked(Array(a.argv.dropFirst()), root: runs.a.root)
        let maskedC = Self.masked(Array(c.argv.dropFirst()), root: runs.c.root)
        XCTAssertEqual(maskedC.sorted(), maskedA.sorted(), "\(parityCase) the same tokens")
        if !parityCase.override {
            XCTAssertEqual(maskedC, maskedA, "\(parityCase) the same argv")
        }
    }

    private static func rootPaths(_ root: URL) -> [String] {
        ["/private" + root.standardizedFileURL.path, root.standardizedFileURL.path, root.resolvingSymlinksInPath().standardizedFileURL.path]
    }

    /// `items` with the side's root written as `$ROOT`.
    private static func masked(_ items: [String], root: URL) -> [String] {
        items.map { item in
            guard let rootPath = rootPaths(root).first(where: { item == $0 || item.hasPrefix($0 + "/") }) else { return item }
            return "$ROOT" + item.dropFirst(rootPath.count)
        }
    }

    /// Each file the record names, with its role, below `root`.
    private static func files(of envelope: ProvenanceEnvelope, under root: URL) -> [String] {
        envelope.files.map { file in "\(file.role) " + (masked([file.path], root: root).first ?? file.path) }.sorted()
    }
}
