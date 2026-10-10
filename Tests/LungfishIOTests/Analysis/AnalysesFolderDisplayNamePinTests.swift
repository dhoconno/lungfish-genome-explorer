// AnalysesFolderDisplayNamePinTests.swift - Freeze of AnalysesFolder tool names before the registry
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// Pins today's display names and known tool set. Display names double as CLI tokens,
/// output folder stems and saved labels, so a registry must reproduce each value exactly.
final class AnalysesFolderDisplayNamePinTests: XCTestCase {
    private static let expectedDisplayNames: [String: String] = [
        "bbmap": "BBMap",
        "bowtie2": "Bowtie2",
        "bwa-mem2": "BWA-MEM2",
        "cz-id": "CZ-ID",
        "esviritu": "EsViritu",
        "flye": "Flye",
        "hifiasm": "Hifiasm",
        "kraken2": "Kraken2",
        "mafft": "MAFFT",
        "megahit": "MEGAHIT",
        "minimap2": "Minimap2",
        "naomgs": "NAO-MGS",
        "nvd": "NVD",
        "ont-genotyping": "ONT Genotyping",
        "pbaa": "pbAA",
        "primer-order": "Primer Order",
        "savont": "Savont",
        "skesa": "SKESA",
        "spades": "SPAdes",
        "taxtriage": "TaxTriage",
        "viralrecon": "Viral Recon",
    ]

    func testKnownToolsEqualsTheLiteral21IDSet() {
        XCTAssertEqual(Self.expectedDisplayNames.count, 21)
        XCTAssertEqual(AnalysesFolder.knownTools, Set(Self.expectedDisplayNames.keys))
    }

    func testDisplayNameForEveryKnownID() {
        for (id, expected) in Self.expectedDisplayNames {
            XCTAssertEqual(AnalysesFolder.displayName(for: id), expected, "display name of \(id)")
        }
    }

    func testDisplayNameFallbackIsCapitalized() {
        XCTAssertEqual(AnalysesFolder.displayName(for: "classification"), "Classification")
        XCTAssertEqual(AnalysesFolder.displayName(for: "foo-bar"), "Foo-Bar")
        XCTAssertEqual(AnalysesFolder.displayName(for: "foo bar"), "Foo Bar")
        XCTAssertEqual(AnalysesFolder.displayName(for: "KRAKEN"), "Kraken")
        XCTAssertEqual(AnalysesFolder.displayName(for: ""), "")
    }

    func testLegacyAndLockSpellingsAreNotKnownIDs() {
        for spelling in ["classification", "kraken", "nao-mgs", "bbtools", "nf-core-viralrecon"] {
            XCTAssertFalse(AnalysesFolder.knownTools.contains(spelling), spelling)
        }
    }
}
