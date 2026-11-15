// RNASeqQuantSigningReplayTests.swift - The record of rnaseq quant is signed when a key is set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 5.1 fix FIX-RS-QUANT-2, item 2a. docs/contracts/RECORDING-PROVENANCE.md ("A result's own record signs when a key is
// set") says the record a result opens first is signed whenever LUNGFISH_PROVENANCE_SIGNING_KEY or
// LUNGFISH_PROVENANCE_SIGNING_KEY_FILE is set, and that each family holds the rule with one completing case under
// `RouteParityHarness.assertNoSignatureLost` and a throwaway key. The rnaseq family had none. The lge_quant stage of C1 ran
// with no key, so `provenance verify` answered exit 3 ("This record carries no signature") on its result, which is right
// for a keyless run and shows nothing about a signed one.
//
// The case runs `rnaseq quant` once with `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under the case root,
// on side A (`SalmonQuantRoute` in process, built as the leaf builds it), side C (the built CLI) and side C' (the recorded
// command replayed). It fails when a side leaves the result's record, `Analyses/<name>.lungfishrnaseq/.lungfish-provenance.json`,
// unsigned, or a record that side A signed unsigned on side C or C'. `assertSignaturesVerify` runs `lungfish-cli provenance
// verify` on every signed record of sides C and C', which must exit 0, then on a copy with one digit edited, which must not.
//
// The set and its salmon index come from the rna-seq pack's gffread and salmon in the managed storage root, built once in
// the case's scratch from the truth probe's input (Tests/Fixtures/rnaseq/salmon-probe-c1, ERCC92) and copied into each side
// root. Sides C and C' name that copy with --storage-root, whose conda folder links to the managed root's, so the CLI finds
// the pack. The test skips through `ToolAvailability` when the managed root lacks salmon or gffread.
//
// It sets a process variable and launches the built lungfish-cli, so its name ends in ReplayTests and it runs in the
// integration tier.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class RNASeqQuantSigningReplayTests: XCTestCase {
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

    private nonisolated static func storage(in root: URL) -> URL {
        root.appendingPathComponent("storage", isDirectory: true)
    }

    /// The result's record in a side root, the one `Analyses/*.lungfishrnaseq` opens first. A root with no result gives a
    /// path that does not exist, which the harness reports as a missing record.
    private nonisolated static func openingRecord(in root: URL) -> URL {
        let analyses = project(in: root).appendingPathComponent("Analyses", isDirectory: true)
        let results = ((try? FileManager.default.contentsOfDirectory(atPath: analyses.path)) ?? [])
            .filter { $0.hasSuffix(".lungfishrnaseq") }.sorted()
        return analyses.appendingPathComponent(results.first ?? "none.lungfishrnaseq", isDirectory: true)
            .appendingPathComponent(ProvenanceWriter.provenanceFilename)
    }

    func testTheQuantResultsRecordLosesNoSignatureOnTheCLIRoute() async throws {
        let cli = try builtCLI()
        let conda = try packConda()
        let scratch = try TestTempDirectory.make(prefix: "rnaseq-quant-signing")
        defer { TestTempDirectory.cleanup(scratch) }
        let seed = try await buildSeed(in: scratch.appendingPathComponent("seed", isDirectory: true))
        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(300))
        let runs = try await harness.runSigned(
            in: scratch.appendingPathComponent("quant", isDirectory: true),
            fixture: { root in try self.writeFixture(root, seed: seed.storage, conda: conda) },
            sideA: { root in await self.sideA(root, setID: seed.setID) },
            sideC: { root in await self.sideC(cli: cli, root: root, setID: seed.setID) }
        )
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        RouteParityHarness.assertNoSignatureLost(runs, opening: Self.openingRecord)
        await harness.assertSignaturesVerify(runs, opening: Self.openingRecord)
    }

    // MARK: - The fixture

    private func builtCLI() throws -> URL {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        return try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
    }

    /// The managed root's conda folder, or a skip when it lacks the pack's salmon or gffread.
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

    /// The probe's set and its salmon index (k 31, no decoys) in a storage root of their own, built by their owners with
    /// the pack's tools as `SalmonQuantRouteProbeConformanceTests` builds them. The records this writes are never signed,
    /// and each side holds them as the fixture, which `assertNoSignatureLost` leaves out.
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

    /// Root A before any side runs, which the harness copies to roots C and C': the seed as the root's storage folder with
    /// the pack linked in, and a project with the probe's one pair bundle, named A_1 as C1's stage names SRR896663.
    private func writeFixture(_ root: URL, seed: URL, conda: URL) throws {
        let storage = Self.storage(in: root)
        try FileManager.default.copyItem(at: seed, to: storage)
        try FileManager.default.createSymbolicLink(at: storage.appendingPathComponent("conda"), withDestinationURL: conda)

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

    private nonisolated static func arguments(in root: URL, setID: String) -> [String] {
        [
            "rnaseq", "quant", bundle(in: root).path, "--project", project(in: root).path, "--name", "Probe", "--set", setID,
            "--decoys", "none", "--storage-root", storage(in: root).path, "--threads", "2", "--quiet",
        ]
    }

    /// Side A. The in-process route, built as the leaf builds it, with the default writer that signs when a key is set.
    private func sideA(_ root: URL, setID: String) async -> RouteParitySideOutcome {
        do {
            let route = SalmonQuantRoute(
                storageRoot: Self.storage(in: root),
                host: RunFitHostFacts(physicalMemoryBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory)))
            let outcome = try await route.run(
                SalmonQuantRequest(
                    bundles: [Self.bundle(in: root)], projectURL: Self.project(in: root), name: "Probe", setID: setID, k: 31,
                    decoys: .none, threads: 2, argv: [CLICommandIdentity.executableName] + Self.arguments(in: root, setID: setID)),
                linuxRoute: Self.linuxRoute)
            return RouteParitySideOutcome(end: .completed, detail: "\(outcome.samples.count) sample")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// Side C. The built CLI on the arguments of the command, which returns the command side C' replays.
    private func sideC(cli: URL, root: URL, setID: String) async -> RouteParitySideOutcome {
        let arguments = Self.arguments(in: root, setID: setID)
        let run = await RouteParityHarness.runCLI(cli, arguments: arguments, timeout: .seconds(300))
        let command = ([CLICommandIdentity.executableName] + arguments)
            .map { $0.contains(" ") ? "'\($0)'" : $0 }
            .joined(separator: " ")
        return RouteParitySideOutcome(end: run.end, detail: run.detail, recordedCommand: command)
    }
}
