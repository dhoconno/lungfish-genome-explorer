// InspectorAnalysesIconPinTests.swift - Freeze of the Inspector Analyses icons beside the sidebar's
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Pins AnalysesSection.iconName(for:) and iconColor(for:) (table T9) for the 23 known analysis ids
// and for an id the registry does not know. Each row also records the symbol the sidebar shows for
// the same id. SidebarPresentationPinTests pins that sidebar column on its own, and this table
// shows where the two surfaces disagree. The Inspector draws the Settings gear for 10 of the 23
// ids, among them kinds the sidebar gives a letter or a symbol of their own. Icons change in
// sub-phase 2.9 and not before, so a failure here means an icon moved and the row is edited in
// the same commit as that decision.

import LungfishIO
import LungfishKit
import SwiftUI
import XCTest
@testable import LungfishApp

@MainActor
final class InspectorAnalysesIconPinTests: XCTestCase {
    /// One analysis id with the symbol the Inspector row shows and the symbol the sidebar shows.
    private struct Row {
        let id: String
        let inspector: String
        let sidebar: String
    }

    /// Registry order. `inspector` is what T9 returns today and `sidebar` is what T7 returns today.
    private static let rows: [Row] = [
        Row(id: "esviritu", inspector: "e.circle.fill", sidebar: "e.circle"),
        Row(id: "kraken2", inspector: "k.circle.fill", sidebar: "k.circle"),
        Row(id: "taxtriage", inspector: "t.circle.fill", sidebar: "t.circle"),
        Row(id: "minimap2", inspector: "m.circle.fill", sidebar: "m.circle"),
        Row(id: "bwa-mem2", inspector: "m.circle.fill", sidebar: "m.circle"),
        Row(id: "bowtie2", inspector: "m.circle.fill", sidebar: "m.circle"),
        Row(id: "bbmap", inspector: "m.circle.fill", sidebar: "m.circle"),
        Row(id: "spades", inspector: "s.circle.fill", sidebar: "s.circle"),
        Row(id: "megahit", inspector: "s.circle.fill", sidebar: "s.circle"),
        Row(id: "skesa", inspector: "s.circle.fill", sidebar: "s.circle"),
        Row(id: "flye", inspector: "s.circle.fill", sidebar: "s.circle"),
        Row(id: "hifiasm", inspector: "s.circle.fill", sidebar: "s.circle"),
        Row(id: "naomgs", inspector: "n.circle.fill", sidebar: "n.circle"),
        Row(id: "nvd", inspector: "gearshape.fill", sidebar: "circle"),
        Row(id: "cz-id", inspector: "gearshape.fill", sidebar: "c.circle"),
        Row(id: "mafft", inspector: "gearshape.fill", sidebar: "rectangle.grid.1x2"),
        Row(id: "ont-genotyping", inspector: "gearshape.fill", sidebar: "tablecells.badge.ellipsis"),
        Row(id: "viralrecon", inspector: "gearshape.fill", sidebar: "v.circle"),
        Row(id: "primer-order", inspector: "gearshape.fill", sidebar: "circle"),
        Row(id: "pbaa", inspector: "gearshape.fill", sidebar: "circle"),
        Row(id: "savont", inspector: "gearshape.fill", sidebar: "circle"),
        Row(id: "illumina-amplicon-genotyping", inspector: "gearshape.fill", sidebar: "circle"),
        Row(id: "ont-sample-bundle-genotyping", inspector: "gearshape.fill", sidebar: "circle"),
    ]

    private static let unknownID = "from-a-newer-build"

    // MARK: - The table

    func testTableCoversEveryRegisteredAnalysisOnce() {
        let ids = Self.rows.map(\.id)
        XCTAssertEqual(ids.count, 23)
        XCTAssertEqual(Set(ids).count, ids.count, "an id appears twice")
        XCTAssertEqual(Set(ids), Set(AnalysisToolRegistry.all.map(\.id.rawValue)))
    }

    // MARK: - The Inspector

    func testInspectorIconForEveryKnownID() {
        for row in Self.rows {
            XCTAssertEqual(AnalysesSection.iconName(for: row.id), row.inspector, "Inspector icon of \(row.id)")
        }
    }

    /// Every kind draws in the one brand orange, and the color does not follow the tool.
    func testInspectorColorIsTheBrandOrangeForEveryKnownID() {
        for row in Self.rows {
            XCTAssertEqual(AnalysesSection.iconColor(for: row.id), Color.lungfishOrangeFallback, "Inspector color of \(row.id)")
        }
    }

    func testInspectorFallsBackToTheGearForAnUnknownID() {
        XCTAssertEqual(AnalysesSection.iconName(for: Self.unknownID), "gearshape.fill")
        XCTAssertEqual(AnalysesSection.iconName(for: ""), "gearshape.fill")
        XCTAssertEqual(AnalysesSection.iconColor(for: Self.unknownID), Color.lungfishOrangeFallback)
    }

    /// The Inspector matches the lowercased tool name, so a differently cased name still finds its
    /// icon. The sidebar looks the raw id up and shows the generic circle for the same names.
    func testInspectorMatchesToolNamesIgnoringCase() {
        XCTAssertEqual(AnalysesSection.iconName(for: "Kraken2"), "k.circle.fill")
        XCTAssertEqual(AnalysesSection.iconName(for: "KRAKEN2"), "k.circle.fill")
        XCTAssertEqual(AnalysesSection.iconName(for: "SPAdes"), "s.circle.fill")
        XCTAssertEqual(AnalysesSection.iconName(for: "BWA-MEM2"), "m.circle.fill")
        XCTAssertEqual(SidebarProjectScanner.analysisIcon(for: "Kraken2"), "circle")
    }

    /// The three legacy aliases are not registry ids, so the Inspector falls through to the gear.
    func testInspectorShowsTheGearForTheLegacyAliases() {
        for alias in ["classification", "kraken", "nao-mgs"] {
            XCTAssertEqual(AnalysesSection.iconName(for: alias), "gearshape.fill", alias)
        }
    }

    // MARK: - The sidebar column

    /// The recorded sidebar column is the live sidebar answer, so it cannot drift from the real one.
    func testRecordedSidebarSymbolMatchesTheSidebarForEveryKnownID() {
        for row in Self.rows {
            XCTAssertEqual(SidebarProjectScanner.analysisIcon(for: row.id), row.sidebar, "sidebar symbol of \(row.id)")
        }
        XCTAssertEqual(SidebarProjectScanner.analysisIcon(for: Self.unknownID), "circle")
    }

    // MARK: - Where the two surfaces disagree

    /// UX finding B9. The gear reads as Settings, and the Inspector draws it for kinds that have
    /// a symbol of their own in the sidebar. The remaining 13 kinds agree apart from the fill.
    func testWhereTheInspectorDisagreesWithTheSidebar() {
        let ids = AnalysisToolRegistry.all.map(\.id.rawValue)
        let live = ids.map { id in
            (id: id, inspector: AnalysesSection.iconName(for: id), sidebar: SidebarProjectScanner.analysisIcon(for: id))
        }

        let sameSymbolFilled = live.filter { $0.inspector == $0.sidebar + ".fill" }.map(\.id)
        let gearBesideASymbol = live.filter { $0.inspector == "gearshape.fill" && $0.sidebar != "circle" }.map(\.id)
        let gearBesideTheGenericCircle = live.filter { $0.inspector == "gearshape.fill" && $0.sidebar == "circle" }.map(\.id)

        XCTAssertEqual(sameSymbolFilled, [
            "esviritu", "kraken2", "taxtriage", "minimap2", "bwa-mem2", "bowtie2", "bbmap",
            "spades", "megahit", "skesa", "flye", "hifiasm", "naomgs",
        ])
        XCTAssertEqual(gearBesideASymbol, ["cz-id", "mafft", "ont-genotyping", "viralrecon"])
        XCTAssertEqual(gearBesideTheGenericCircle, [
            "nvd", "primer-order", "pbaa", "savont",
            "illumina-amplicon-genotyping", "ont-sample-bundle-genotyping",
        ])
        XCTAssertEqual(
            sameSymbolFilled.count + gearBesideASymbol.count + gearBesideTheGenericCircle.count, ids.count,
            "every id lands in one of the three groups"
        )
    }
}
