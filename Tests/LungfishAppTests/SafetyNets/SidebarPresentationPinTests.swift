// SidebarPresentationPinTests.swift - Freeze of sidebar badges and icons before the registry
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Pins SidebarProjectScanner.classifierBatchBadge (T5) and analysisIcon (T7) for the
// 21 known analysis ids and an unknown id. The Inspector icon table (T9) is a private
// method of the AnalysesSection view and no behaviour exposes it, so it is not pinned here.

import XCTest
@testable import LungfishApp

final class SidebarPresentationPinTests: XCTestCase {
    private static let expectedBadges: [String: String?] = [
        "bbmap": nil, "bowtie2": nil, "bwa-mem2": nil, "cz-id": "CZ", "esviritu": "ES",
        "flye": nil, "hifiasm": nil, "kraken2": "K2", "mafft": nil, "megahit": nil,
        "minimap2": nil, "naomgs": "NM", "nvd": "NVD", "ont-genotyping": nil, "pbaa": nil,
        "primer-order": nil, "savont": nil, "skesa": nil, "spades": nil, "taxtriage": "TT",
        "viralrecon": nil,
    ]

    private static let expectedIcons: [String: String] = [
        "bbmap": "m.circle", "bowtie2": "m.circle", "bwa-mem2": "m.circle", "cz-id": "c.circle",
        "esviritu": "e.circle", "flye": "s.circle", "hifiasm": "s.circle", "kraken2": "k.circle",
        "mafft": "rectangle.grid.1x2", "megahit": "s.circle", "minimap2": "m.circle",
        "naomgs": "n.circle", "nvd": "circle", "ont-genotyping": "tablecells.badge.ellipsis",
        "pbaa": "circle", "primer-order": "circle", "savont": "circle", "skesa": "s.circle",
        "spades": "s.circle", "taxtriage": "t.circle", "viralrecon": "v.circle",
    ]

    func testTablesCoverTheKnownTools() {
        XCTAssertEqual(Set(Self.expectedBadges.keys), Set(Self.expectedIcons.keys))
        XCTAssertEqual(Self.expectedBadges.count, 21)
    }

    func testClassifierBatchBadgeForEveryKnownID() {
        for (id, expected) in Self.expectedBadges {
            XCTAssertEqual(SidebarProjectScanner.classifierBatchBadge(for: id), expected, "badge of \(id)")
        }
    }

    func testClassifierBatchBadgeForAnUnknownID() {
        XCTAssertNil(SidebarProjectScanner.classifierBatchBadge(for: "from-a-newer-build"))
        XCTAssertNil(SidebarProjectScanner.classifierBatchBadge(for: "Kraken2"))
    }

    func testAnalysisIconForEveryKnownID() {
        for (id, expected) in Self.expectedIcons {
            XCTAssertEqual(SidebarProjectScanner.analysisIcon(for: id), expected, "icon of \(id)")
        }
    }

    func testAnalysisIconForAnUnknownID() {
        XCTAssertEqual(SidebarProjectScanner.analysisIcon(for: "from-a-newer-build"), "circle")
        XCTAssertEqual(SidebarProjectScanner.analysisIcon(for: "Kraken2"), "circle")
    }
}
