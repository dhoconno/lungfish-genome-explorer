// NaoMgsSummaryExportPinTests.swift - Pins the NAO-MGS table export bytes on the shared builder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M1 for M4 (QA 1), on the builder since M4 step 6. The view applies its search, column
// filter, sort and sample selection to the rows it shows (`displayedRows`), and `NaoMgsSummaryExport.summaryTSV`,
// which `nao-mgs export table` calls, writes only those rows in that order with the shown metadata column. The
// in-app writer's record facts are held by side A of `NaoMgsExportCLIGUIParityReplayTests`, frozen, and the leaf's
// by `NaoMgsExportTableCommandTests`.

import XCTest
import AppKit
@testable import LungfishNaoMgsUI
@testable import LungfishIO
import LungfishWorkflow
@testable import LungfishKit
@testable import LungfishCore

final class NaoMgsSummaryExportPinTests: XCTestCase {
    static let header = [
        "sample", "taxon_id", "name", "hit_count", "unique_read_count", "pcr_duplicate_count",
        "avg_identity", "avg_bit_score", "avg_edit_distance", "accession_count", "Cohort",
    ].joined(separator: "\t")

    /// The search drops `Delta phage`, the filter `hits >= 10` drops `Beta virus`, the selection drops `sample-C`,
    /// and the sort by hits ascending puts `sample-B` first.
    @MainActor func testBytesHoldTheShownRowsInTheShownOrder() throws {
        let vc = try configuredController()
        let rows = vc.testTableExportWriterState.rows
        let metadata = vc.metadataColumnController
        let content = NaoMgsSummaryExport.summaryTSV(
            rows: rows,
            metadataHeaders: metadata.exportHeaders,
            metadataValuesBySample: Dictionary(uniqueKeysWithValues: Set(rows.map(\.sample)).map {
                ($0, metadata.exportValues(for: $0))
            })
        )

        XCTAssertEqual(content, [
            Self.header,
            "sample-B\t4\tGamma virus\t20\t18\t2\t99.50\t200.0\t1.0\t1\tcontrol",
            "sample-A\t1\tAlpha virus\t30\t28\t2\t99.50\t200.0\t1.0\t1\tcase",
        ].joined(separator: "\n") + "\n")
    }

    // MARK: - Fixture

    @MainActor private func configuredController() throws -> NaoMgsResultViewController {
        let vc = NaoMgsResultViewController()
        isolateLayouts(vc)
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
                sampleName: "naomgs-pin", sourceFilePath: "/tmp/virus_hits.tsv", hitCount: 145, taxonCount: 5,
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
