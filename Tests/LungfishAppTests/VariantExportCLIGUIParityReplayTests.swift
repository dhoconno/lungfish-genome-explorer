// VariantExportCLIGUIParityReplayTests.swift - The variant drawer's bookmark and template exports against their CLI leaves
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.39, ARCH ruling on the export shape 1.7, on lane Q30's harness. Each case runs on three sides
// that start as copies of one reference bundle whose two variant tracks hold databases of two samples each, with
// bookmarks stored in each database's `variant_bookmarks` table. The drawer on each side opens the bundle through
// `AnnotationSearchIndex`, as the viewer opens it.
//
// - Side A is the in-app writer. For the bookmarked variants (B6) it is `exportBookmarkedVariants` with its row loop
//   and source list and `BookmarkedVariantExportService.export` as they stood at ebdf72d3a (the c2 side A fix),
//   frozen in this file since the lane deletes them. For the sample template (B11) it is the drawer's closure,
//   `VariantSampleTemplateExportPinTests.frozenTemplate`, which wrote no record.
// - Side C is the drawer's begin helper with the invocation the drawer builds, which begins the row and runs the
//   built `lungfish-cli variants export bookmarked` or `variants export sample-template` on `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded.
//
// A against C compares what 1.7 names, the payload byte for byte, the record's inputs with their digests, the
// output's digest and size, and every `resolved` key both sides write, with no file but the record differing. The
// template had no record at the base, so its record is a prediction row whole. The identity fields of the record
// are prediction rows of the lane report (BIO 7), pinned on each side by `assertPredictedRecordChanges`. C against C'
// compares everything under the contract's masks. Nothing is declared, so the old writers go with no key (R-A1, C4).
//
// The cancels run through the real transport. The leaf holds inside its transaction on
// `LUNGFISH_VIEWER_EXPORT_HOLD_FILE`, the row's Cancel stops it, and neither the output nor its record is left
// (ARCH ruling 1.6, X14).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishOperations
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class VariantExportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case bookmarksOverTwoTracks
        case bookmarksOverTwoTracksOfOneDatabase
        case sampleTemplateTSV
        case sampleTemplateCSV

        var isBookmarked: Bool { self == .bookmarksOverTwoTracks || self == .bookmarksOverTwoTracksOfOneDatabase }
        var sharesOneDatabase: Bool { self == .bookmarksOverTwoTracksOfOneDatabase }
        var outputName: String {
            switch self {
            case .bookmarksOverTwoTracks, .bookmarksOverTwoTracksOfOneDatabase: "bookmarked variants.tsv"
            case .sampleTemplateTSV: "sample template.tsv"
            case .sampleTemplateCSV: "sample template.csv"
            }
        }
    }

    /// The `resolved` keys both sides of the bookmarked variants export write, compared value for value.
    static let sharedBookmarkResolvedKeys: Set<String> = ["variantCount"]
    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"
    nonisolated static let bundleName = "Ref.lungfishref"
    static let metadataFields = ["collection_date", "country"]

    var scratch: URL!
    var harness: RouteParityHarness!

    override func setUp() async throws {
        scratch = try TestTempDirectory.make(prefix: "variant-export-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .files, replayTimeout: .seconds(60))
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// B6. Each track's database holds its own bookmarks, read database by database in track order.
    func testBookmarksOverTwoTracksMatch() async throws {
        let runs = try await assertParity(.bookmarksOverTwoTracks)
        XCTAssertEqual(try String(contentsOf: Self.outputURL(in: runs.c.root, for: .bookmarksOverTwoTracks), encoding: .utf8), """
        ID\tType\tChrom\tPos\tRef\tAlt\tQuality\tFilter
        rs200\tSNP\tchr1\t200\tC\tT\t.\tq10
        rs50\tSNP\tchr2\t50\tG\tA\t12.5\tPASS
        rs10\tSNP\tchr3\t10\tT\tC\t60.0\tPASS

        """)
        let record = try Self.envelope(in: runs.c.root, for: .bookmarksOverTwoTracks)
        XCTAssertEqual(record.options.resolvedDefaults["variantCount"]?.integerValue, 3)
    }

    /// B6. Two tracks over one database repeat its bookmarks on both sides, and both records name it once.
    func testBookmarksOverTwoTracksOfOneDatabaseMatch() async throws {
        let runs = try await assertParity(.bookmarksOverTwoTracksOfOneDatabase)
        XCTAssertEqual(try String(
            contentsOf: Self.outputURL(in: runs.c.root, for: .bookmarksOverTwoTracksOfOneDatabase), encoding: .utf8
        ), """
        ID\tType\tChrom\tPos\tRef\tAlt\tQuality\tFilter
        rs200\tSNP\tchr1\t200\tC\tT\t.\tq10
        rs50\tSNP\tchr2\t50\tG\tA\t12.5\tPASS
        rs200\tSNP\tchr1\t200\tC\tT\t.\tq10
        rs50\tSNP\tchr2\t50\tG\tA\t12.5\tPASS

        """)
        let record = try Self.envelope(in: runs.c.root, for: .bookmarksOverTwoTracksOfOneDatabase)
        XCTAssertEqual(record.options.resolvedDefaults["variantCount"]?.integerValue, 4)
    }

    /// B11 in TSV. Each database's samples in `sampleNames()` order, a sample whose name and source file match an
    /// earlier row's, ignoring case, left out, and an empty cell for each metadata column (BIO 5).
    func testSampleTemplateTSVMatches() async throws {
        let runs = try await assertParity(.sampleTemplateTSV)
        XCTAssertEqual(try String(contentsOf: Self.outputURL(in: runs.c.root, for: .sampleTemplateTSV), encoding: .utf8), """
        sample_name\tsource_file\tcollection_date\tcountry
        SAMPLE_A\tfirst.vcf\t\t
        SAMPLE_B\tfirst.vcf\t\t
        SAMPLE_C\tsecond.vcf\t\t
        sample_a\tsecond.vcf\t\t

        """)
    }

    /// B11 in CSV, which the drawer writes for a `.csv` name.
    func testSampleTemplateCSVMatches() async throws {
        let runs = try await assertParity(.sampleTemplateCSV)
        XCTAssertEqual(try String(contentsOf: Self.outputURL(in: runs.c.root, for: .sampleTemplateCSV), encoding: .utf8), """
        sample_name,source_file,collection_date,country
        SAMPLE_A,first.vcf,,
        SAMPLE_B,first.vcf,,
        SAMPLE_C,second.vcf,,
        sample_a,second.vcf,,

        """)
    }

    /// ARCH ruling 1.6 and X14, for the bookmarked variants leaf.
    func testACancelledBookmarkExportExits125AndLeavesNoFileAndNoRecord() async throws {
        try await assertCancelLeavesNothing(.bookmarksOverTwoTracks)
    }

    /// ARCH ruling 1.6 and X14, for the sample template leaf.
    func testACancelledTemplateExportExits125AndLeavesNoFileAndNoRecord() async throws {
        try await assertCancelLeavesNothing(.sampleTemplateTSV)
    }

    /// The row's Cancel stops the leaf inside its transaction, the row reads Cancelled with no alert, and the row's
    /// command, cancelled on the launcher every CLI route uses, exits 125 inside the grace. Neither leaves the output
    /// or its record.
    private func assertCancelLeavesNothing(_ parityCase: Case) async throws {
        let root = scratch.appendingPathComponent("cancel-\(parityCase.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeBundle(root, sharesOneDatabase: parityCase.sharesOneDatabase)
        let output = Self.outputURL(in: root, for: parityCase)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let hold = root.appendingPathComponent("held")
        let invocation = try await Self.drawerInvocation(root, parityCase)

        let failures = VariantExportParityFailures()
        let begun = try XCTUnwrap(Self.begin(
            parityCase,
            invocation: invocation,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            environmentAdditions: [Self.holdFileVariable: hold.path]
        ) { failure in failures.messages.append(failure.message) })
        let held = try await Self.waitForFile(hold)
        XCTAssertTrue(held, "the leaf reached its transaction")
        OperationCenter.shared.cancel(id: begun.operationID)
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(item?.state, .cancelled)
        XCTAssertEqual(failures.messages, [], "a cancel shows no alert")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")

        try FileManager.default.removeItem(at: hold)
        let arguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(item?.cliCommand))
        let run = await RouteParityHarness.runCLI(
            harness.cliBinary, arguments: arguments, timeout: .seconds(60),
            environment: [Self.holdFileVariable: hold.path],
            cancelWhen: { FileManager.default.fileExists(atPath: hold.path) }
        )
        let observed = try XCTUnwrap(run.cancel, "the run was cancelled through the transport, it ended \(run.detail)")
        CLISIGTERMHarness.assertCancelledExit(status: observed.status, elapsed: observed.elapsed, detail: " \(run.detail)")
        await CLISIGTERMHarness.assertNoProcessLeft(observed.tree)
        XCTAssertEqual(run.end, .cancelled)
        XCTAssertTrue(run.stdout.contains("The export was cancelled. No file was written."), run.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")
    }
}
