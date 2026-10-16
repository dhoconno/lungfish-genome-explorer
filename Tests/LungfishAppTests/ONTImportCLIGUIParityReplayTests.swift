// ONTImportCLIGUIParityReplayTests.swift - The ONT import on the CLI route against the command it records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A53 M3 (panel decisions G1, C4, C5 and C11, ARCH 2, 3 and 7, BIO 1 and 2, UX 1, 3 and 4,
// ruling A53-M3). The window's ONT import runs `lungfish-cli fastq import-ont --format json` on the L6
// runner. Phase 2.11 (K3) deleted the in-process route and its hidden key, so
// the parity class runs one import of the shared three-barcode run folder (ONTImportFreezeFixture) on the
// two sides of RouteParityHarness that are left.
//
// - Side C, the CLI route, ONTImportOperationCoordinator on the built command.
// - Side C', the command side C's row recorded, rebased and run by the built CLI.
//
// BIO 1 reads the reads of each barcode from each side's manifest. C against C' declares nothing. UX 1 and 3
// read the row of side C: a bar that only rises, and a log that keeps each stage word the row showed. The
// failure case shows the words of a failed import in the row.
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

    // MARK: - C against C'

    func testTheChunkedImportAgreesWithItsRecordedCommand() async throws {
        try await assertParity(.chunkedRun, storageMode: .chunked)
    }

    func testTheFlattenedImportAgreesWithItsRecordedCommand() async throws {
        try await assertParity(.flattenedRun, storageMode: .flattened)
    }

    private func assertParity(_ parityCase: Case, storageMode: ONTImportStorageMode) async throws {
        var rowC: MappingRouteRow?
        let runs = try await ReadsRouteParity.runCAndCPrime(
            harness,
            in: scratch.appendingPathComponent("parity-\(parityCase.rawValue)", isDirectory: true),
            fixture: Self.writeFixture,
            sideC: { root in
                let (row, item) = try await ReadsRouteParity.record(title: Self.title) {
                    self.startImport(root: root, storageMode: storageMode)
                }
                rowC = ReadsRouteParity.rooted(row, root)
                return ReadsRouteParity.outcome(of: item, recordsCommand: true)
            }
        )

        let sides = [runs.c, runs.cPrime]
        XCTAssertEqual(sides.map(\.outcome.end), [.completed, .completed], sides.map(\.outcome.detail).joined(separator: "\n"))
        // C against C' declares nothing. The command the row recorded rebuilds the same project.
        let found = try harness.differences(runs.c, runs.cPrime)
        RouteParityHarness.assertNoFailures(found.map { "\($0.id): \($0.detail)" }, in: "\(parityCase), C against C'")

        // BIO 1 and 2, equal reads per barcode on both sides, from each side's own manifest.
        let expected = ONTImportFreezeFixture.readsPerBarcode.map { "\($0.barcode)=\($0.reads)" }
        for run in sides {
            let folder = Self.project(in: run.root).appendingPathComponent("Imports/Run1", isDirectory: true)
            let manifest = try XCTUnwrap(DemultiplexManifest.load(from: folder), "side \(run.side) wrote no manifest")
            XCTAssertEqual(manifest.barcodes.map { "\($0.barcodeID)=\($0.readCount)" }, expected, "side \(run.side), reads per barcode")
        }

        // The command side C recorded is the argv its runner launched, ARCH 2.
        let command = try XCTUnwrap(runs.c.outcome.recordedCommand)
        XCTAssertTrue(command.hasSuffix(" --format json"), command)

        // UX 1 and 3, the CLI route's bar only rises, and its log keeps each stage word it showed. The last
        // detail is the end of the row, which is not a stage word and is not logged.
        let row = try XCTUnwrap(rowC)
        XCTAssertEqual(row.bar, MappingRouteRow.heldBar(row.bar), "the CLI route's bar only rises")
        for word in row.shown.dropLast() where !word.isEmpty {
            XCTAssertTrue(row.logged.contains("info \(word)"), "the CLI route's log keeps the stage word \(word)")
        }
    }

    // MARK: - A failed import (W3)

    /// A chunk the import cannot read fails it. The sheet keeps the words of the failure (decision W3), which
    /// the command forwards in its `failed` line.
    func testAFailedImportFailsTheRowAndLeavesNoPartialBundle() async throws {
        let root = scratch.appendingPathComponent("failure-C", isDirectory: true)
        try Self.writeFixture(root)
        let chunk = Self.source(in: root).appendingPathComponent("barcode01/chunk_1.fastq")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: chunk.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: chunk.path) }

        let (_, item) = try await ReadsRouteParity.record(title: Self.title) {
            startImport(root: root, storageMode: .chunked)
        }

        XCTAssertEqual(item.state, .failed, item.detail)
        XCTAssertFalse(item.detail.isEmpty)
        XCTAssertEqual(item.bundleURLs, [], "a failed import lists nothing")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: Self.project(in: root).appendingPathComponent("Imports/Run1/barcode01.lungfishfastq").path
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

    /// Starts the import of the run folder under `root` on a coordinator that runs the built command, and
    /// returns at once, as the window's task does.
    private func startImport(root: URL, storageMode: ONTImportStorageMode) {
        let coordinator = ONTImportOperationCoordinator(
            operationCenter: OperationCenter.shared,
            runner: CLIReadsRunner(cliURLOverride: cliBinary)
        )
        Task { @MainActor in
            _ = try? await coordinator.importDirectory(
                sourceURL: Self.source(in: root), projectURL: Self.project(in: root), includeUnclassified: true,
                concurrency: Self.concurrency, storageMode: storageMode, routeContext: nil
            )
        }
    }
}
