// NaoMgsSummaryExportPinTests.swift - Pins the NAO-MGS summary export at the 12.31 base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M1 for M4 (QA 1). These pins hold today's in-app writer, `writeSummaryTSV`, before
// `nao-mgs export table` replaces it. The view applies its search, column filter, sort and sample selection to the
// rows it shows (`displayedRows`), so the bytes hold only those rows in that order, with the shown metadata column.
// The record names the tool `Lungfish.app` with its own argv. The M4 parity class reads these facts as side A.

import XCTest
import AppKit
@testable import LungfishNaoMgsUI
@testable import LungfishIO
import LungfishWorkflow
@testable import LungfishKit
@testable import LungfishCore

@MainActor
private final class NaoMgsRecordingFailurePresenter: ExportFailurePresenting {
    private(set) var alerts: [(title: String, message: String)] = []
    func presentExportFailure(title: String, message: String, in window: NSWindow?) {
        alerts.append((title, message))
    }
}

final class NaoMgsSummaryExportPinTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaoMgsSummaryExportPin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    static let header = [
        "sample", "taxon_id", "name", "hit_count", "unique_read_count", "pcr_duplicate_count",
        "avg_identity", "avg_bit_score", "avg_edit_distance", "accession_count", "Cohort",
    ].joined(separator: "\t")

    /// The search drops `Delta phage`, the filter `hits >= 10` drops `Beta virus`, the selection drops `sample-C`,
    /// and the sort by hits ascending puts `sample-B` first.
    @MainActor func testBytesHoldTheShownRowsInTheShownOrder() throws {
        let vc = try configuredController()
        let outputURL = folder.appendingPathComponent("summary.tsv")
        try vc.writeSummaryTSV(to: outputURL)

        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), [
            Self.header,
            "sample-B\t4\tGamma virus\t20\t18\t2\t99.50\t200.0\t1.0\t1\tcontrol",
            "sample-A\t1\tAlpha virus\t30\t28\t2\t99.50\t200.0\t1.0\t1\tcase",
        ].joined(separator: "\n") + "\n")
    }

    /// The record facts lane 12.31 predicts will move (tool, kind, argv, workflow name), the `resolved` keys and
    /// the inputs, which name the manifest's source file.
    @MainActor func testRecordNamesTheAppWriterAndTheViewState() throws {
        let vc = try configuredController()
        let outputURL = folder.appendingPathComponent("summary.tsv")
        try vc.writeSummaryTSV(to: outputURL)

        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        )
        let argv = ["Lungfish.app", "export-naomgs-summary", "--output", outputURL.path]
        XCTAssertEqual(envelope.workflowName, "lungfish app naomgs summary export")
        XCTAssertEqual(envelope.toolName, "Lungfish.app")
        XCTAssertEqual(envelope.tool.kind, "gui")
        XCTAssertEqual(envelope.argv, argv)
        XCTAssertEqual(envelope.durableReplayArgv, argv)
        let resolved = envelope.options.resolvedDefaults
        XCTAssertEqual(resolved.keys.sorted(), [
            "columnFilterComposition", "columnFilters", "metadataColumns", "rowCount", "sampleName",
            "selectedSamples", "sortDescriptors", "sourceSampleCount",
        ])
        XCTAssertEqual(resolved["rowCount"]?.integerValue, 2)
        XCTAssertEqual(resolved["selectedSamples"]?.arrayValue?.compactMap(\.stringValue), ["sample-A", "sample-B"])
        XCTAssertEqual(resolved["sourceSampleCount"]?.integerValue, 3)
        XCTAssertEqual(resolved["columnFilterComposition"]?.stringValue, "all")
        XCTAssertEqual(resolved["columnFilters"]?.arrayValue?.count, 1)
        guard case .dictionary(let sort)? = resolved["sortDescriptors"]?.arrayValue?.first else {
            return XCTFail("one sort descriptor, \(String(describing: resolved["sortDescriptors"]))")
        }
        XCTAssertEqual(sort["key"]?.stringValue, "hits")
        XCTAssertEqual(sort["ascending"], .boolean(true))
        XCTAssertEqual(resolved["metadataColumns"]?.arrayValue?.compactMap(\.stringValue), ["Cohort"])
        XCTAssertEqual(resolved["sampleName"]?.stringValue, "naomgs-pin")
        XCTAssertEqual(envelope.options.explicit.keys.sorted(), ["format", "outputPath"])
        XCTAssertEqual(envelope.options.defaults["format"]?.stringValue, "tsv")
        XCTAssertEqual(
            envelope.files.filter { $0.role == .input }.map { URL(fileURLWithPath: $0.path).lastPathComponent },
            ["virus_hits.tsv"]
        )
    }

    /// A failed write reaches `ResultExportCoordinator.reportFailure`, whose words UX 1 keeps.
    @MainActor func testFailureAlertWords() throws {
        let vc = try configuredController()
        let blocked = folder.appendingPathComponent("summary.tsv", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let presenter = NaoMgsRecordingFailurePresenter()
        do {
            try vc.writeSummaryTSV(to: blocked)
            XCTFail("a folder in the output's place fails the export")
        } catch {
            ResultExportCoordinator.reportFailure(
                fileName: blocked.lastPathComponent, error: error, window: nil, presenter: presenter
            )
            XCTAssertEqual(presenter.alerts.map(\.title), ["Export Failed"])
            XCTAssertEqual(presenter.alerts.map(\.message), ["Could not write summary.tsv: \(error.localizedDescription)"])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: blocked).path))
    }

    // MARK: - Fixture

    @MainActor private func configuredController() throws -> NaoMgsResultViewController {
        let source = folder.appendingPathComponent("virus_hits.tsv")
        try Data("source\n".utf8).write(to: source)
        let vc = NaoMgsResultViewController()
        vc.loadViewIfNeeded()
        vc.configureWithCachedRows(
            [
                Self.row(sample: "sample-A", taxId: 1, name: "Alpha virus", hits: 30),
                Self.row(sample: "sample-A", taxId: 2, name: "Delta phage", hits: 50),
                Self.row(sample: "sample-A", taxId: 3, name: "Beta virus", hits: 5),
                Self.row(sample: "sample-B", taxId: 4, name: "Gamma virus", hits: 20),
                Self.row(sample: "sample-C", taxId: 5, name: "Alpha virus", hits: 40),
            ],
            manifest: NaoMgsManifest(
                sampleName: "naomgs-pin", sourceFilePath: source.path, hitCount: 145, taxonCount: 5,
                topTaxon: "Delta phage", topTaxonId: 2
            ),
            awaitingDatabase: false
        )
        vc.applySampleMetadata(try SampleMetadataStore(
            csvData: Data("Sample\tCohort\nsample-A\tcase\nsample-B\tcontrol\nsample-C\tcase\n".utf8),
            knownSampleIds: ["sample-A", "sample-B", "sample-C"]
        ))
        vc.metadataColumnController.visibleColumns = ["Cohort"]
        vc.testSetTaxonomySearchText("virus")
        vc.columnHeaderFilterMenu(
            replaceFilterFor: "hits",
            with: ColumnFilter(columnId: "hits", op: .greaterOrEqual, value: "10")
        )
        vc.columnHeaderFilterMenu(sortByKey: "hits", ascending: true)
        vc.samplePickerState.selectedSamples = ["sample-A", "sample-B"]
        vc.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertEqual(vc.testDisplayedTaxonOrder, ["sample-B:4", "sample-A:1"])
        return vc
    }

    private static func row(sample: String, taxId: Int, name: String, hits: Int) -> NaoMgsTaxonSummaryRow {
        NaoMgsTaxonSummaryRow(
            sample: sample, taxId: taxId, name: name, hitCount: hits, uniqueReadCount: hits - 2,
            avgIdentity: 99.5, avgBitScore: 200, avgEditDistance: 1, pcrDuplicateCount: 2, accessionCount: 1,
            topAccessions: ["NC_\(taxId)"], bamPath: nil, bamIndexPath: nil
        )
    }
}
