// PhylogeneticTreeSupportPresentationTests.swift - support columns, legend and rooting text (V1, V3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishIO
@testable import LungfishPhylogeneticsUI

@MainActor
final class PhylogeneticTreeSupportPresentationTests: XCTestCase {
    private let iqTreeLabels = [PhylogeneticTreeSupportLabel.shALRT, PhylogeneticTreeSupportLabel.ufBoot]

    // MARK: - Pure presentation

    func testColumnsAreOnePerRecordedLabel() {
        let columns = PhylogeneticTreeSupportPresentation.columns(labels: iqTreeLabels)
        XCTAssertEqual(columns.map(\.title), ["SH-aLRT", "UFBoot"])
        XCTAssertEqual(columns.map(\.id), ["support-SH-aLRT", "support-UFBoot"])
    }

    func testColumnsWithoutLabelsKeepTheSingleSupportColumn() {
        let columns = PhylogeneticTreeSupportPresentation.columns(labels: [])
        XCTAssertEqual(columns.map(\.title), ["Support"])
        XCTAssertEqual(columns.map(\.id), ["support"])
    }

    func testCellValuesSplitThePairAndSupportTypeReadsTheLabels() {
        let node = labelledNode(shALRT: "99.9", ufBoot: "100")
        XCTAssertEqual(PhylogeneticTreeSupportPresentation.cellValue(for: node, columnID: "support-SH-aLRT"), "99.9")
        XCTAssertEqual(PhylogeneticTreeSupportPresentation.cellValue(for: node, columnID: "support-UFBoot"), "100")
        XCTAssertEqual(PhylogeneticTreeSupportPresentation.supportText(for: node), "99.9/100")
        XCTAssertEqual(PhylogeneticTreeSupportPresentation.supportType(for: node), "SH-aLRT/UFBoot")
        let rows = PhylogeneticTreeSupportPresentation.detailRows(for: node)
        XCTAssertEqual(rows.map(\.0), ["Support", "Support Type"])
        XCTAssertEqual(rows.map(\.1), ["99.9/100", "SH-aLRT/UFBoot"])
    }

    func testUnlabelledSupportKeepsTodaysTextAndInterpretation() {
        let node = node(rawLabel: "90", support: PhylogeneticTreeSupport(rawValue: "90", interpretation: "bootstrap"))
        XCTAssertEqual(PhylogeneticTreeSupportPresentation.cellValue(for: node, columnID: "support"), "90")
        XCTAssertEqual(PhylogeneticTreeSupportPresentation.supportText(for: node), "90")
        XCTAssertEqual(PhylogeneticTreeSupportPresentation.supportType(for: node), "bootstrap")
    }

    func testStrengthUsesUFBootWhenPresentAndGreysOnlyMissingValues() {
        XCTAssertEqual(
            PhylogeneticTreeSupportPresentation.strength(for: labelledNode(shALRT: "10", ufBoot: "96"), labels: iqTreeLabels),
            .strong
        )
        XCTAssertEqual(
            PhylogeneticTreeSupportPresentation.strength(for: labelledNode(shALRT: "99", ufBoot: "90"), labels: iqTreeLabels),
            .weak
        )
        XCTAssertEqual(
            PhylogeneticTreeSupportPresentation.strength(for: node(rawLabel: nil, support: nil), labels: iqTreeLabels),
            .missing
        )
    }

    func testStrengthFallsBackToTheFirstLabel() {
        let shOnly = node(
            rawLabel: "85",
            support: PhylogeneticTreeSupport(rawValue: "85", interpretation: "SH-aLRT"),
            supportValues: [PhylogeneticTreeSupportValue(label: "SH-aLRT", rawValue: "85", value: 85)]
        )
        XCTAssertEqual(PhylogeneticTreeSupportPresentation.strength(for: shOnly, labels: ["SH-aLRT"]), .strong)
        XCTAssertEqual(PhylogeneticTreeSupportPresentation.legendText(labels: ["SH-aLRT"]), "SH-aLRT 80 or higher strong")
    }

    func testLegendNamesTheColouredLabelFirst() {
        XCTAssertEqual(
            PhylogeneticTreeSupportPresentation.legendText(labels: iqTreeLabels),
            "UFBoot 95 or higher strong, SH-aLRT 80 or higher"
        )
        XCTAssertNil(PhylogeneticTreeSupportPresentation.legendText(labels: []))
    }

    func testRootingText() {
        XCTAssertEqual(PhylogeneticTreeSupportPresentation.rootingText(isRooted: false), "Unrooted (drawn root is arbitrary)")
        XCTAssertEqual(PhylogeneticTreeSupportPresentation.rootingText(isRooted: true), "Rooted")
    }

    // MARK: - Controller

    func testControllerShowsOneColumnPerLabelAndTheUnrootedNote() throws {
        let bundleURL = try makeBundle(labels: iqTreeLabels)
        let controller = PhylogeneticTreeViewController()
        controller.loadViewIfNeeded()
        try controller.displayBundle(at: bundleURL)

        let columnIDs = Set(controller.testingNodeColumnWidths.keys)
        XCTAssertTrue(columnIDs.isSuperset(of: ["support-SH-aLRT", "support-UFBoot"]))
        XCTAssertFalse(columnIDs.contains("support"))
        XCTAssertTrue(controller.testingSummaryText.contains("Unrooted (drawn root is arbitrary)"))

        let row = try XCTUnwrap(controller.testingRowIndex(ofSupportText: "99.9/100"))
        XCTAssertEqual(controller.testingNodeCellAccessibilityValue(column: "support-SH-aLRT", row: row), "99.9")
        XCTAssertEqual(controller.testingNodeCellAccessibilityValue(column: "support-UFBoot", row: row), "100")
    }

    func testControllerShowsTheLegendOnlyInSupportColorMode() throws {
        let bundleURL = try makeBundle(labels: iqTreeLabels)
        let controller = PhylogeneticTreeViewController()
        controller.loadViewIfNeeded()
        try controller.displayBundle(at: bundleURL)

        XCTAssertTrue(controller.testingSupportLegendIsHidden)
        controller.testingSetTreeColorMode(.support)
        XCTAssertFalse(controller.testingSupportLegendIsHidden)
        XCTAssertEqual(controller.testingSupportLegendText, "UFBoot 95 or higher strong, SH-aLRT 80 or higher")
        controller.testingSetTreeColorMode(.branchLength)
        XCTAssertTrue(controller.testingSupportLegendIsHidden)
    }

    func testControllerWithoutLabelsKeepsTheSupportColumnAndHidesTheLegend() throws {
        let bundleURL = try makeBundle(labels: nil, newick: "((A:0.1,B:0.2)90:0.3,C:0.4);\n")
        let controller = PhylogeneticTreeViewController()
        controller.loadViewIfNeeded()
        try controller.displayBundle(at: bundleURL)

        XCTAssertTrue(controller.testingNodeColumnWidths.keys.contains("support"))
        controller.testingSetTreeColorMode(.support)
        XCTAssertTrue(controller.testingSupportLegendIsHidden)
    }

    func testSelectionStateReadsSupportTypeFromLabels() throws {
        let bundleURL = try makeBundle(labels: iqTreeLabels)
        let controller = PhylogeneticTreeViewController()
        controller.loadViewIfNeeded()
        var lastState: PhylogeneticTreeSelectionState?
        controller.onSelectionStateChanged = { lastState = $0 }
        try controller.displayBundle(at: bundleURL)

        let row = try XCTUnwrap(controller.testingRowIndex(ofSupportText: "99.9/100"))
        controller.testingNodeTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        let rows = try XCTUnwrap(lastState?.detailRows)
        XCTAssertTrue(rows.contains { $0.0 == "Support" && $0.1 == "99.9/100" })
        XCTAssertTrue(rows.contains { $0.0 == "Support Type" && $0.1 == "SH-aLRT/UFBoot" })
    }

    // MARK: - Fixtures

    private func labelledNode(shALRT: String, ufBoot: String) -> PhylogeneticTreeNormalizedNode {
        node(
            rawLabel: "\(shALRT)/\(ufBoot)",
            support: PhylogeneticTreeSupport(rawValue: ufBoot, interpretation: "UFBoot"),
            supportValues: [
                PhylogeneticTreeSupportValue(label: "SH-aLRT", rawValue: shALRT, value: Double(shALRT) ?? 0),
                PhylogeneticTreeSupportValue(label: "UFBoot", rawValue: ufBoot, value: Double(ufBoot) ?? 0),
            ]
        )
    }

    private func node(
        rawLabel: String?,
        support: PhylogeneticTreeSupport?,
        supportValues: [PhylogeneticTreeSupportValue] = []
    ) -> PhylogeneticTreeNormalizedNode {
        PhylogeneticTreeNormalizedNode(
            id: "n1",
            rawLabel: rawLabel,
            displayLabel: rawLabel ?? "n1",
            parentID: "root",
            childIDs: ["a", "b"],
            isTip: false,
            branchLength: 0.1,
            cumulativeDivergence: 0.1,
            metadata: [:],
            support: support,
            descendantTipCount: 2,
            supportValues: supportValues
        )
    }

    private func makeBundle(
        labels: [String]?,
        newick: String = "(A:0.1,B:0.2,(C:0.3,(D:0.1,E:0.2)99.9/100:0.05)85/90:0.4);\n"
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhyloSupportPresentation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("run.treefile")
        try newick.write(to: sourceURL, atomically: true, encoding: .utf8)
        let bundleURL = directory.appendingPathComponent("tree.lungfishtree", isDirectory: true)
        _ = try PhylogeneticTreeBundleImporter.importTree(
            from: sourceURL,
            to: bundleURL,
            options: PhylogeneticTreeImportOptions(
                sourceFormat: "newick",
                supportLabels: labels,
                branchLengthUnit: labels == nil ? nil : "substitutions per site"
            )
        )
        return bundleURL
    }
}
