// PopUpMirrorInDrawerTests.swift - The drawer's pull-downs and the gene tab bar are reachable as AX actions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishKit
@testable import LungfishApp
@testable import LungfishCore

/// The annotation drawer's Profiles, Group Presets and haploid-mode buttons
/// and its export button mirror their menus as custom actions, reinstalled
/// whenever the menu is rebuilt, and performing one does what choosing the
/// item does. The gene tab bar's overflow pop-up does the same.
@MainActor
final class PopUpMirrorInDrawerTests: XCTestCase {

    private func makeVariantDrawer() -> AnnotationTableDrawerView {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 900, height: 240))
        drawer.activeTab = .variants
        drawer.activeVariantSubtab = .calls
        drawer.configureColumnsForTab(.variants)
        drawer.displayedAnnotations = [
            AnnotationSearchIndex.SearchResult(
                name: "rs1", chromosome: "chr1", start: 9, end: 10,
                trackId: "caller-a", trackName: "Caller A", type: "SNP",
                ref: "A", alt: "G", variantRowId: 1
            ),
        ]
        drawer.tableView.reloadData()
        return drawer
    }

    func testProfilePullDownMirrorsItsItemsAndAProfileActionAppliesTheProfile() throws {
        let drawer = makeVariantDrawer()
        drawer.rebuildProfileMenu()
        let actions = try XCTUnwrap(drawer.profileButton.accessibilityCustomActions())
        let names = actions.map(\.name)
        XCTAssertEqual(names.first, "No Profile")
        XCTAssertEqual(names.last, "Save Current as Profile\u{2026}")
        XCTAssertFalse(names.contains("Profiles"), "the pull-down's title item is not a command")
        // Built-in profiles are listed only when their tokens apply to the
        // loaded variants, so a bare drawer may list none.
        if let builtIn = FilterProfile.builtInProfiles.first(where: { profile in names.contains(profile.name) }) {
            let action = try XCTUnwrap(actions.first { $0.name == builtIn.name })
            drawer.variantFilterText = "stale"
            XCTAssertEqual(action.handler?(), true)
            XCTAssertEqual(drawer.activeSmartTokens, Set(builtIn.smartTokens))
            XCTAssertEqual(drawer.variantFilterText, builtIn.filterText)
        }
        drawer.variantFilterText = "stale"
        XCTAssertEqual(actions[0].handler?(), true)
        XCTAssertTrue(drawer.activeSmartTokens.isEmpty, "No Profile clears the tokens")
        XCTAssertEqual(drawer.variantFilterText, "")
    }

    func testHaploidModePopUpMirrorsItsThreeModesAndSwitchesMode() throws {
        let drawer = makeVariantDrawer()
        drawer.rebuildHaploidModeMenu()
        let actions = try XCTUnwrap(drawer.haploidModeButton.accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), ["Auto", "Haploid", "Diploid"])
        XCTAssertEqual(actions[1].handler?(), true)
        XCTAssertEqual(drawer.haploidModeSelection, .haploid)
        XCTAssertEqual(actions[2].handler?(), true)
        XCTAssertEqual(drawer.haploidModeSelection, .diploid)
    }

    func testGroupPresetPullDownMirrorFollowsTheRebuiltMenu() throws {
        let drawer = makeVariantDrawer()
        drawer.rebuildSampleGroupPresetMenu()
        XCTAssertNil(drawer.sampleGroupPresetButton.accessibilityCustomActions(), "no groups, no commands")
        drawer.currentSampleDisplayState.sampleGroups = [
            SampleGroup(name: "Cases", sampleNames: ["s1"]),
            SampleGroup(name: "Controls", sampleNames: ["s2"]),
        ]
        drawer.rebuildSampleGroupPresetMenu()
        let actions = try XCTUnwrap(drawer.sampleGroupPresetButton.accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), ["Cases", "Controls", "Show All Samples"])
    }

    func testExportButtonMirrorsTheExportMenuForTheCurrentSelection() throws {
        let drawer = makeVariantDrawer()
        var actions = try XCTUnwrap(drawer.exportButton.accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), [
            "All Matching Rows\u{2026} > Excel Workbook (.xlsx)", "All Matching Rows\u{2026} > CSV",
            "All Matching Rows\u{2026} > TSV", "All Matching Rows\u{2026} > JSON",
        ], "nothing selected, so only the all-rows scope is offered")
        drawer.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        actions = try XCTUnwrap(drawer.exportButton.accessibilityCustomActions())
        XCTAssertEqual(actions.count, 8)
        XCTAssertEqual(actions[4].name, "Selected Rows (1)\u{2026} > Excel Workbook (.xlsx)")
    }

    func testGeneTabBarOverflowPopUpMirrorsTheHiddenGenesAndSelectsOne() throws {
        final class Spy: GeneTabBarDelegate {
            var selected: [String] = []
            func geneTabBar(_ bar: GeneTabBarView, didSelectGene region: GeneRegion) { selected.append(region.name) }
            func geneTabBarDidRequestDismiss(_ bar: GeneTabBarView) {}
        }
        let bar = GeneTabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: 30))
        let spy = Spy()
        bar.delegate = spy
        let regions = (0..<(GeneTabBarView.maxVisibleTabs + 3)).map {
            GeneRegion(name: "GENE\($0)", chromosome: "chr1", start: $0 * 100, end: $0 * 100 + 50)
        }
        bar.setGeneRegions(regions)
        let actions = try XCTUnwrap(bar.testOverflowPopup.accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), ["GENE\(GeneTabBarView.maxVisibleTabs) (chr1)", "GENE\(GeneTabBarView.maxVisibleTabs + 1) (chr1)", "GENE\(GeneTabBarView.maxVisibleTabs + 2) (chr1)"])
        XCTAssertEqual(actions[1].handler?(), true)
        XCTAssertEqual(spy.selected, ["GENE\(GeneTabBarView.maxVisibleTabs + 1)"])
    }
}
