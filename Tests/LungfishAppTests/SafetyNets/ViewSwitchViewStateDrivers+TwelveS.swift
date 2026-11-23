// ViewSwitchViewStateDrivers+TwelveS.swift - The 12S result viewer's driver for the view state cases (VS-CORE item 3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The fixture (RoutingSafetyNetFixtures.twelveSResultBundle) has human in HG002 and in the extraction blank and rhesus
// macaque in MMU-17. The change picks HG002 and MMU-17, filters for "Homo", sorts by sample, widens the scientific
// name column and selects the one row left, HG002's human row.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishTwelveSUI

@MainActor
struct TwelveSViewStateDriver: ViewStateDriver {
    let kind = "12S"

    private func viewer(in harness: ViewSwitchWindowHarness) -> TwelveSAmpliconResultViewController? {
        harness.split.viewerController.twelveSAmpliconResultViewController
    }

    func isShown(in harness: ViewSwitchWindowHarness) -> Bool {
        viewer(in: harness) != nil
    }

    func change(in harness: ViewSwitchWindowHarness) throws {
        let viewer = try XCTUnwrap(viewer(in: harness))
        viewer.testingSetSelectedSamples(["HG002", "MMU-17"])
        viewer.setSearchTextForTesting("Homo")
        viewer.testingSetTargetSort(key: "sampleName", ascending: true)
        viewer.testingSetActiveTableColumnWidth(identifier: "scientificName", width: 301)
        viewer.selectTargetForTesting(row: 0)
    }

    /// The filter field, the sample button, the sort, the column width, the rows and the selected rows.
    func read(in harness: ViewSwitchWindowHarness) throws -> [String] {
        let viewer = try XCTUnwrap(viewer(in: harness))
        let table = viewer.targetTable
        let sort = viewer.testingTargetSortDescriptor
        let width = table.tableView.tableColumn(withIdentifier: .init("scientificName"))?.width ?? 0
        let selected = table.tableView.selectedRowIndexes.map { row in
            "\(viewer.testingTargetText(row: row, column: "sampleName")) \(viewer.testingTargetText(row: row, column: "scientificName"))"
        }
        return [
            "filter \(viewer.testingHeaderSearchField.stringValue)",
            "samples \(viewer.sampleFilterButton.title)",
            "sort \(sort?.key ?? "none") \(sort.map { $0.ascending ? "ascending" : "descending" } ?? "")",
            "scientific name width \(Int(width))",
            "rows \(table.tableView.numberOfRows)",
            "selected \(selected.joined(separator: ", "))",
        ]
    }

    /// Touches the count matrix, so the table's modification time and the data key change.
    func changeBundle(of fixture: ViewSwitchFixture) throws {
        let bundle = try XCTUnwrap(fixture.item.url)
        let counts = bundle.appendingPathComponent("sample-target-counts.tsv")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: counts.path)
    }

    /// The filter text is a search text, so a changed key drops it and both chosen samples' rows show. The samples,
    /// the sort, the width and the selected row by its identity come back (VS B4, B5, B6).
    func readingAfterChangedBundle(changed: [String]) -> [String] {
        var reading = changed
        reading[0] = "filter "
        reading[4] = "rows 2"
        return reading
    }

    var lineAfterChangedBundle: String? {
        "The data changed since your last visit, so your filters were not kept."
    }
}
