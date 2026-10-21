// VariantSampleMetadataCLIGUIParityReplayTests.swift - The sample metadata import in process against variants import-sample-metadata
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A43 M3, plan decisions C3, C4, C5 and G1, on lane Q30's harness and on the
// pattern of AnnotationTrackAttachCLIGUIParityReplayTests. The variant table's Import Metadata
// button imports a CSV or TSV file of sample metadata into the variant databases of a bundle. One
// case runs on three sides that start as copies of one bundle and one one-column metadata file. A
// second column would write the keys of `samples.metadata` in another order from run to run, and
// the harness compares the rows of a database as text.
//
// - Side A is the in-process route at the base, the call the button made,
//   `VariantSampleMetadataImportService.importMetadata`. Its record names the argv side C's
//   command records, the change of the recorded command the closed gaps intend
//   (docs/contracts/CLI-EQUIVALENCE.md), so A against C compares everything else.
// - Side C is the CLI route, the table's own launcher `importSampleMetadata`, which begins the row
//   and runs `CLIBundleEditRunner`, which launches the built `lungfish-cli variants
//   import-sample-metadata`. Its row records the command.
// - Side C' is the harness's replay of that command.
//
// The case declares only the identity paths of R2 (MD62), so A against C holds only those and C against C' is empty (C4).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the
// integration tier, where the CLI is built.

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
final class VariantSampleMetadataCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case importSampleMetadata
    }

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "variant-metadata-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(30))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testTheMetadataRowWritesWhatTheInProcessImportWrote() async throws {
        let result = try await harness.assertParity(
            Case.importSampleMetadata,
            declared: [RouteParityHarness.appIdentityDifference([Case.importSampleMetadata: 12])],
            in: scratch.appendingPathComponent("import", isDirectory: true),
            fixture: { root in
                let fixture = try VariantEditFixture.make(in: root, withTrackManifest: true)
                _ = try fixture.writeOneColumnMetadata()
            },
            sideA: { root in await self.sideA(root) },
            sideC: { root in await self.sideC(root) }
        )
        XCTAssertEqual(result.runs.a.outcome.end, .completed, result.runs.a.outcome.detail)
        XCTAssertEqual(result.runs.c.outcome.end, .completed, result.runs.c.outcome.detail)
        XCTAssertEqual(result.runs.c.outcome.detail, "Data and provenance updated", "the row's complete words")
        XCTAssertEqual(result.runs.cPrime.outcome.end, .completed, result.runs.cPrime.outcome.detail)
    }

    // MARK: - The sides

    private func paths(in root: URL) -> (bundle: URL, database: URL, file: URL) {
        let bundle = root.appendingPathComponent("reference.lungfishref", isDirectory: true)
        return (bundle, bundle.appendingPathComponent("variants.db"), root.appendingPathComponent("one-column.tsv"))
    }

    /// Side A. The in-process import the button made at the base, with the target the table
    /// builds from its handle of the track. Its record names the argv side C's command records,
    /// which starts with the path the transport launched, as the command records its observed argv.
    private func sideA(_ root: URL) async -> RouteParitySideOutcome {
        let (bundle, database, file) = paths(in: root)
        let argv = [harness.cliBinary.path]
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

    /// Side C. The table's launcher, which begins the row and runs the built CLI on the argv it
    /// records. It returns the row's command, which side C' replays.
    private func sideC(_ root: URL) async -> RouteParitySideOutcome {
        let (bundle, _, file) = paths(in: root)
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.searchIndex = AnnotationSearchIndex()
        let center = OperationCenter()
        center.failureReportStore = .temporaryForTesting()
        guard let task = drawer.importSampleMetadata(
            fileURL: file, format: .tsv, bundleURL: bundle, center: center, cliURLOverride: harness.cliBinary
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
