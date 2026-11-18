// RNASeqQuantDialogConformanceTests.swift - The quantify row of the FASTQ operations dialog with real salmon (RS-DIALOG-M1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Sub-phase 5.4, lane RS-DIALOG, brief item "parity replay". The row runs the same `lungfish-cli rnaseq quant` that a script runs.
// This case runs it with the rna-seq pack's salmon and gffread on the truth probe's small input (Tests/Fixtures/rnaseq/salmon-probe-c1,
// one pair of SRR896663 and the ERCC92 set), on the three sides of `RouteParityHarness`.
//
// - Side A is a script. The built `lungfish-cli` runs the argv of the request and nothing else.
// - Side C is the row. `RNASeqQuantRoute.launch` begins the Operations row and runs the built CLI on `CLIRNASeqQuantRunner`, the
//   launcher the app uses. The row records its command.
// - Side C' is that recorded command, replayed by the harness on the same CLI.
//
// What the case asserts.
// 1. All three sides complete and each makes one result. The row's `operationType` is `.rnaSeqQuantification`, its recorded command
//    starts `lungfish-cli rnaseq quant `, and side C' replays it as one line.
// 2. `source/A_1/quant.sf` and the two count tables are byte for byte the same on the three sides.
// 3. The result is a bundle, so the harness compares every file under root A against root C, and under root C against root C', as
//    a `.bundle` through `OutputEquivalence`. The masks are the standard policy and the four of `MaskPolicy.rnaSeqQuant`
//    (RNASeqQuantParityMasks.swift, each held by RNASeqQuantParityMaskTests), and no difference is declared. A difference that no
//    mask of the Masks row of docs/contracts/CLI-EQUIVALENCE.md covers fails the case and is a finding in the lane report.
//
// What it leaves out. The reference set, its salmon index and their use entries sit in one storage root outside the three roots, as
// the app's storage root sits outside any project, and all three sides read it through `LUNGFISH_STORAGE_ROOT`. That root is not
// compared. A use entry is named by the sha256 of the result's path, which differs by side by construction, and a record writes a
// path under the temporary folder as `<workspace>/...`, a spelling of a run root that `Masks.roots` does not read. No mask of the
// row covers either, so the case does not put that root under the roots (see Findings in the lane report). The pack stays outside as
// well, through `LUNGFISH_CONDA_ROOT`.
//
// The set and its salmon index (k 31, no decoys) are built once in the case's scratch by their owners with the pack's tools, as
// `RNASeqQuantSigningReplayTests` builds them.
//
// salmon and gffread are the pack's in the managed storage root. Run the case as one command with the root given by `env`:
//   env LUNGFISH_STORAGE_ROOT=<root holding the rna-seq pack> LUNGFISH_REQUIRE_TOOLS=1 swift test --skip-update \
//       --filter RNASeqQuantDialogConformanceTests
// Without `LUNGFISH_REQUIRE_TOOLS=1` a root that lacks the pack skips the case, and with it a skip fails
// (`ToolAvailability.skipOrFail`). `RNASeqQuantDialogTests` is the stand-in beside it and runs in every tier. This class holds
// `Conformance` in its name, so no gate tier runs it.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class RNASeqQuantDialogConformanceTests: XCTestCase {
    private nonisolated static let projectName = "Probe.lungfish"
    private nonisolated static let linuxRoute = "Run salmon on Linux and import its folders with lungfish-cli import rnaseq"

    private nonisolated static var probe: URL {
        RNASeqFixtures.root.appendingPathComponent("salmon-probe-c1", isDirectory: true)
    }

    private nonisolated static func project(in root: URL) -> URL {
        root.appendingPathComponent(projectName, isDirectory: true)
    }

    private nonisolated static func bundle(in root: URL) -> URL {
        project(in: root).appendingPathComponent("Imports/A_1.lungfishfastq", isDirectory: true)
    }

    /// The results a root holds, by folder name.
    private nonisolated static func results(in root: URL) -> [String] {
        let analyses = project(in: root).appendingPathComponent("Analyses", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: analyses.path)) ?? [])
            .filter { $0.hasSuffix(".lungfishrnaseq") }.sorted()
    }

    // MARK: - The case

    func testTheRowsRunEqualsTheRunOfAScriptAndTheCommandItShowsReplaysToTheSame() async throws {
        let cli = try builtCLI()
        let conda = try packConda()
        let scratch = try TestTempDirectory.make(prefix: "rnaseq-quant-dialog-parity")
        defer { TestTempDirectory.cleanup(scratch) }
        let seed = try await buildSeed(in: scratch.appendingPathComponent("storage", isDirectory: true))
        let environment: @Sendable (URL) -> [String: String] = { _ in
            ["LUNGFISH_STORAGE_ROOT": seed.storage.path, "LUNGFISH_CONDA_ROOT": conda.path]
        }
        let harness = RouteParityHarness(
            cliBinary: cli, kind: .bundle, masks: .rnaSeqQuant, replayTimeout: .seconds(300), environment: environment)
        // Each case root sits five folders below the temporary folder, since a record's sidecar search lists each input's folder and
        // four above it.
        let caseRoot = scratch.appendingPathComponent("cases/of/the/rnaseq-quant-dialog", isDirectory: true)
        let result = try await harness.assertParity(
            "onePairAgainstTheProbeSet", declared: [], in: caseRoot,
            fixture: { root in try self.writeFixture(root) },
            sideA: { root in await self.scriptSide(cli: cli, root: root, setID: seed.setID, environment: environment(root)) },
            sideC: { root in await self.rowSide(cli: cli, root: root, setID: seed.setID, environment: environment(root)) }
        )
        let runs = result.runs
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        // Every side made one result, and it holds salmon's own file for the one sample.
        for run in runs.all {
            let made = Self.results(in: run.root)
            XCTAssertEqual(made.count, 1, "side \(run.side) holds \(made)")
            let quant = Self.project(in: run.root).appendingPathComponent("Analyses", isDirectory: true)
                .appendingPathComponent(made.first ?? "none", isDirectory: true)
                .appendingPathComponent("source/A_1/quant.sf")
            XCTAssertTrue(FileManager.default.fileExists(atPath: quant.path), "side \(run.side) has no \(quant.path)")
        }
        // The counts are the scientific content, so they are also compared by their bytes, which the whole-tree match above does
        // after its masks.
        for file in ["source/A_1/quant.sf", "counts/genes.counts.tsv", "counts/transcripts.counts.tsv"] {
            let bytes = try runs.all.map { run -> Data in
                let name = try XCTUnwrap(Self.results(in: run.root).first)
                return try Data(contentsOf: Self.project(in: run.root).appendingPathComponent("Analyses/\(name)/\(file)"))
            }
            XCTAssertFalse(bytes[0].isEmpty, file)
            XCTAssertEqual(bytes[0], bytes[1], "\(file) of the script and of the row")
            XCTAssertEqual(bytes[1], bytes[2], "\(file) of the row and of its replay")
        }
        let command = try XCTUnwrap(runs.c.outcome.recordedCommand)
        XCTAssertTrue(command.hasPrefix("lungfish-cli rnaseq quant "), command)
        XCTAssertEqual(runs.cPrime.replayedArguments.count, 1, "the row records one command")
    }

    // MARK: - The fixture

    private func builtCLI() throws -> URL {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        return try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
    }

    /// The managed root's conda folder, or a skip (a failure under `LUNGFISH_REQUIRE_TOOLS=1`) when it lacks the pack's
    /// salmon or gffread.
    private func packConda() throws -> URL {
        let root = ManagedStorageConfigStore().currentLocation().rootURL
        for (environment, name) in [("salmon", "salmon"), ("gffread", "gffread")] {
            let tool = root.appendingPathComponent("conda/envs/\(environment)/bin/\(name)")
            guard FileManager.default.isExecutableFile(atPath: tool.path) else {
                try ToolAvailability.skipOrFail("\(name) of the rna-seq pack is not in \(root.path)")
            }
        }
        return root.appendingPathComponent("conda", isDirectory: true)
    }

    /// The probe's set and its salmon index (k 31, no decoys) in a storage root of their own, built by their owners with the
    /// pack's tools. The records this writes are never signed. All three sides read this one root.
    private func buildSeed(in storage: URL) async throws -> (storage: URL, setID: String) {
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let writer = ProvenanceWriter(signingProvider: nil)
        let host = RunFitHostFacts(physicalMemoryBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory))
        let roomy: RunFitPreflight.FreeSpaceReader = { _ in 1_000_000_000_000 }
        let set = try await ReferenceSetOwner(storageRoot: storage, provenanceWriter: writer).build(ReferenceSetRequest(
            name: "ERCC92 probe", species: "Synthetic construct", assemblyName: "ERCC92", annotationSource: "ERCC",
            annotationRelease: "92", genome: Self.probe.appendingPathComponent("ERCC92.fa"),
            annotation: Self.probe.appendingPathComponent("ERCC92.gtf"), extras: [], layout: .lge))
        let cache = SalmonIndexCache(storageRoot: storage, provenanceWriter: writer, host: host, freeSpace: roomy)
        _ = try await cache.ensure(SalmonIndexRequest(setID: set.manifest.id, k: 31, decoys: .none), linuxRoute: Self.linuxRoute)
        return (storage, set.manifest.id)
    }

    /// Root A before any side runs, which the harness copies to roots C and C': a project with the probe's one pair bundle, named
    /// A_1 as C1's stage names SRR896663.
    private func writeFixture(_ root: URL) throws {
        func lines(_ name: String) throws -> [Substring] {
            try GzipInputStream(url: Self.probe.appendingPathComponent(name)).readAllSync().split(separator: "\n")
        }
        let one = try lines("SRR896663_1.fastq.gz"), two = try lines("SRR896663_2.fastq.gz")
        XCTAssertEqual(one.count, two.count)
        var text = ""
        for start in stride(from: 0, to: min(one.count, two.count), by: 4) {
            text += one[start..<start + 4].joined(separator: "\n") + "\n" + two[start..<start + 4].joined(separator: "\n") + "\n"
        }
        let bundle = Self.bundle(in: root)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let reads = bundle.appendingPathComponent("reads.fastq")
        try Data(text.utf8).write(to: reads)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: .interleaved, pairingSource: .detected)), for: reads)
    }

    // MARK: - The sides

    /// What the quantify pane asks for in `root`, which the row and the script both run.
    private func request(in root: URL, setID: String) -> RNASeqQuantRunRequest {
        RNASeqQuantRunRequest(
            bundleURLs: [Self.bundle(in: root)], projectURL: Self.project(in: root), setID: setID, k: 31, decoys: .none,
            trim: false, polyGTrimming: false)
    }

    /// Side A. The built CLI on the argv of the request, as a script runs it.
    private func scriptSide(cli: URL, root: URL, setID: String, environment: [String: String]) async -> RouteParitySideOutcome {
        let run = await RouteParityHarness.runCLI(
            cli, arguments: request(in: root, setID: setID).argv, timeout: .seconds(300), environment: environment)
        return RouteParitySideOutcome(end: run.end, detail: run.detail)
    }

    /// Side C. The row's route on the built CLI. It returns the command the Operations row recorded, which side C' replays.
    private func rowSide(cli: URL, root: URL, setID: String, environment: [String: String]) async -> RouteParitySideOutcome {
        let center = OperationCenter()
        let runner = CLIRNASeqQuantRunner(cliURLProvider: { cli }, environmentAdditions: environment)
        guard let task = RNASeqQuantRoute.launch(request(in: root, setID: setID), operations: center, runner: runner),
              let id = center.items.first?.id
        else { return RouteParitySideOutcome(end: .failed, detail: "begin refused the run") }
        await task.value
        guard let item = center.items.first(where: { $0.id == id }) else {
            return RouteParitySideOutcome(end: .failed, detail: "the row is gone")
        }
        XCTAssertEqual(item.operationType, .rnaSeqQuantification)
        let end: RouteParityEnd = item.state == .completed ? .completed : .failed
        return RouteParitySideOutcome(end: end, detail: item.errorMessage ?? item.detail, recordedCommand: item.cliCommand)
    }
}
