// VariantSampleMetadataSigningReplayTests.swift - An imported variant sample metadata file keeps its signature on the CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L1 (the ruling of the A52 whole-lane review, Q6). The case of
// VariantSampleMetadataCLIGUIParityReplayTests runs with no signing key. This one runs its import again with
// `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under the case root, on side A (the in-process
// import), side C (the table's launcher and `CLIBundleEditRunner` launching `variants import-sample-metadata`)
// and side C' (the recorded command), and fails when the CLI route leaves unsigned a record the in-process route
// signs, or the bundle's record that the result opens first.
//
// It launches the built lungfish-cli, so its name ends in ReplayTests and it runs in the integration tier.

import Foundation
import LungfishCore
import XCTest
@testable import LungfishApp
@testable import LungfishOperations
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class VariantSampleMetadataSigningReplayTests: XCTestCase {
    /// The bundle's record in a side root, which the import rewrites and the result opens first.
    private nonisolated static func openingRecord(in root: URL) -> URL {
        root.appendingPathComponent("reference.lungfishref", isDirectory: true)
            .appendingPathComponent(ProvenanceWriter.provenanceFilename)
    }

    func testAnImportedMetadataFileLosesNoSignatureOnTheCLIRoute() async throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        let scratch = try TestTempDirectory.make(prefix: "variant-metadata-signing")
        defer { TestTempDirectory.cleanup(scratch) }
        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(30))
        let runs = try await harness.runSigned(
            in: scratch.appendingPathComponent("import", isDirectory: true),
            fixture: { root in
                let fixture = try VariantEditFixture.make(in: root, withTrackManifest: true)
                _ = try fixture.writeOneColumnMetadata()
            },
            sideA: { root in await self.sideA(root, cli: cli) },
            sideC: { root in await self.sideC(root, cli: cli) }
        )
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        RouteParityHarness.assertNoSignatureLost(runs, opening: Self.openingRecord)
        await harness.assertSignaturesVerify(runs, opening: Self.openingRecord)
    }

    // MARK: - The sides

    private func paths(in root: URL) -> (bundle: URL, database: URL, file: URL) {
        let bundle = root.appendingPathComponent("reference.lungfishref", isDirectory: true)
        return (bundle, bundle.appendingPathComponent("variants.db"), root.appendingPathComponent("one-column.tsv"))
    }

    /// Side A. The in-process import the button made at the base, with the target the table builds from its
    /// handle of the track.
    private func sideA(_ root: URL, cli: URL) async -> RouteParitySideOutcome {
        let (bundle, database, file) = paths(in: root)
        let argv = [cli.path]
            + VariantSampleMetadataImportService.importMetadataArguments(metadataURL: file, format: .tsv, bundleURL: bundle)
            + ["--format", "json"]
        do {
            _ = try VariantSampleMetadataImportService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).importMetadata(
                from: file,
                format: .tsv,
                bundleURL: bundle,
                targets: [VariantSampleMetadataImportTarget(databaseURL: database, trackName: VariantEditFixture.trackID)],
                invocationArgv: argv
            )
            return RouteParitySideOutcome(end: .completed, detail: "Data and provenance updated")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// Side C. The table's launcher, which begins the row and runs the built CLI on the argv it records. It
    /// returns the row's command, which side C' replays.
    private func sideC(_ root: URL, cli: URL) async -> RouteParitySideOutcome {
        let (bundle, _, file) = paths(in: root)
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.searchIndex = AnnotationSearchIndex()
        let center = OperationCenter()
        center.failureReportStore = .temporaryForTesting()
        guard let task = drawer.importSampleMetadata(
            fileURL: file, format: .tsv, bundleURL: bundle, center: center, cliURLOverride: cli
        ) else {
            return RouteParitySideOutcome(end: .failed, detail: "the row did not start")
        }
        await task.value
        let item = center.items.first
        let completed = item?.state == .completed
        return RouteParitySideOutcome(
            end: completed ? .completed : .failed,
            detail: (completed ? item?.detail : item?.errorMessage) ?? "no row",
            recordedCommand: item?.cliCommand
        )
    }
}
