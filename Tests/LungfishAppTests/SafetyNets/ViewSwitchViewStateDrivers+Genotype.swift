// ViewSwitchViewStateDrivers+Genotype.swift - The genotype result viewer's driver for the view state cases (VS-GENO)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The fixture (RoutingSafetyNetFixtures.genotypeResultBundle with calls) holds one cynomolgus macaque, DW472, and one
// call. The change goes through `applyDisplayState`, the path of the viewport's presentation control and of the
// Inspector: the other summary view, the leading panel layout, no cell colour, highlights of filtered cells shown and
// both percent bases on the sample's retained reads. The reading is the state the viewer draws from, field by field.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishGenotypeUI
import LungfishIO
@testable import LungfishKit

@MainActor
struct GenotypeViewStateDriver: ViewStateDriver {
    let kind = "Genotype"

    private func viewer(in harness: ViewSwitchWindowHarness) -> GenotypeResultViewController? {
        harness.split.viewerController.genotypeResultViewController
    }

    /// Shown once the route configured the viewer, which it does in the same turn as the show, and the open's
    /// restore has run.
    func isShown(in harness: ViewSwitchWindowHarness) -> Bool {
        viewer(in: harness)?.viewMemoryIsSettled == true
    }

    func change(in harness: ViewSwitchWindowHarness) throws {
        let viewer = try XCTUnwrap(viewer(in: harness))
        var state = viewer.testingDisplayState
        state.summaryViewMode = state.summaryViewMode == .matrix ? .outline : .matrix
        state.layout = .listLeading
        state.cellColorMode = .none
        state.hideFilteredHighlights = false
        state.supportDenominator = .sampleRetained
        state.matrixPercentDenominator = .sampleRetained
        viewer.applyDisplayState(state)
    }

    /// The summary view, the layout, the cell colour, the highlight switch and the two percent bases.
    func read(in harness: ViewSwitchWindowHarness) throws -> [String] {
        let state = try XCTUnwrap(viewer(in: harness)).testingDisplayState
        return [
            "summary \(state.summaryViewMode.rawValue)",
            "layout \(state.layout.rawValue)",
            "cell color \(state.cellColorMode.rawValue)",
            "hide filtered highlights \(state.hideFilteredHighlights)",
            "support basis \(state.supportDenominator.rawValue)",
            "matrix percent basis \(state.matrixPercentDenominator.rawValue)",
        ]
    }

    /// Moves the call tables' modification time, as a rerun that rewrote them would, so the data key differs.
    func changeBundle(of fixture: ViewSwitchFixture) throws {
        let bundle = try XCTUnwrap(fixture.item.url)
        let tables = try FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "csv" }
        XCTAssertFalse(tables.isEmpty, "the fixture holds its call tables")
        for table in tables {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: table.path)
        }
    }

    /// The presentation fields need no data key and come back. The percent bases change values, so on a changed
    /// bundle they start at the open's, the viewed locus (VS B6).
    func readingAfterChangedBundle(changed: [String]) -> [String] {
        var reading = changed
        reading[4] = "support basis \(ONTGenotypeSupportDenominator.viewedLocus.rawValue)"
        reading[5] = "matrix percent basis \(ONTGenotypeSupportDenominator.viewedLocus.rawValue)"
        return reading
    }

    var lineAfterChangedBundle: String? { ViewMemoryWords.dataChanged(.filters) }

    /// The line over the viewer, which the viewer draws itself.
    func resetLineWords(in harness: ViewSwitchWindowHarness) -> String? {
        viewer(in: harness)?.view.subviews.compactMap { $0 as? ViewMemoryResetLineView }.first?.words
    }

    /// The words of the settings line (word 5c) at the foot of the viewer, nil while it is hidden.
    func settingsLineWords(in harness: ViewSwitchWindowHarness) -> String? {
        let line = viewer(in: harness)?.view.subviews.compactMap { $0 as? ViewMemoryFilterLineView }.first
        return line.flatMap { $0.isHidden ? nil : $0.displayedText }
    }
}
