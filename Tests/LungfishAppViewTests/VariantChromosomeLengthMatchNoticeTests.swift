// VariantChromosomeLengthMatchNoticeTests.swift - SCI-14 user-visible length-match note
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
import os.log
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

/// SCI-14: when `ChromosomeAliasResolver` matches a VCF contig to a reference
/// contig purely by length (no name/alias/version/synonym match), that fact
/// must be surfaced to the user in the GUI, not only logged. These tests
/// verify:
/// 1. `buildVariantChromosomeAliasMapWithLengthMatchNotes` produces a note
///    naming both contigs when (and only when) the match was length-only.
/// 2. `AnnotationTableDrawerView` turns those notes into a visible tooltip
///    on the "Variants" tab segment, and clears it when there is nothing to
///    warn about.
@MainActor
final class VariantChromosomeLengthMatchNoticeTests: XCTestCase {

    private let logger = Logger(subsystem: "com.lungfish.tests", category: "VariantChromosomeLengthMatchNoticeTests")

    private func makeDatabase(
        chromosome: String,
        position: Int,
        contigLength: Int?,
        directory: URL
    ) throws -> VariantDatabase {
        let vcfURL = directory.appendingPathComponent("\(UUID().uuidString).vcf")
        let dbURL = directory.appendingPathComponent("\(UUID().uuidString).db")
        let contigLine = contigLength.map { "##contig=<ID=\(chromosome),length=\($0)>\n" } ?? ""
        let vcf = """
        ##fileformat=VCFv4.2
        \(contigLine)#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        \(chromosome)\t\(position)\t.\tA\tG\t.\tPASS\t.
        """
        try vcf.write(to: vcfURL, atomically: true, encoding: .utf8)
        _ = try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)
        return try VariantDatabase(url: dbURL)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VariantChromosomeLengthMatchNoticeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A length-only match (small contig, matched purely by MAX(position)
    /// falling within the proportional tolerance) must produce a note that
    /// names both the VCF contig and the reference contig it was matched to.
    func testLengthOnlyMatchProducesUserFacingNote() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try makeDatabase(chromosome: "totally_different_name", position: 950, contigLength: nil, directory: dir)
        let bundleChromosomes = [
            ChromosomeInfo(name: "scaffold_1", length: 1000, offset: 0, lineBases: 70, lineWidth: 71)
        ]

        let (aliasMap, notes) = SequenceViewerView.buildVariantChromosomeAliasMapWithLengthMatchNotes(
            bundleChromosomes: bundleChromosomes,
            variantDB: db,
            sequenceViewerLogger: logger,
            includeMaxPositionFallback: true
        )

        XCTAssertEqual(aliasMap["scaffold_1"], "totally_different_name")
        XCTAssertEqual(notes.count, 1)
        let note = try XCTUnwrap(notes.first)
        XCTAssertTrue(note.contains("totally_different_name"), "Note must name the VCF contig: \(note)")
        XCTAssertTrue(note.contains("scaffold_1"), "Note must name the reference contig: \(note)")
        XCTAssertTrue(note.localizedCaseInsensitiveContains("length"), "Note must say the match was by length: \(note)")
    }

    /// A name/version match (no length fallback needed) must produce zero
    /// notes -- the whole point is that name-based matches are reliable and
    /// don't need a caveat.
    func testNameMatchProducesNoNote() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // "MN908947.3" resolves to "MN908947" by version-suffix stripping,
        // a name-based strategy, not length.
        let db = try makeDatabase(chromosome: "MN908947.3", position: 100, contigLength: 29_903, directory: dir)
        let bundleChromosomes = [
            ChromosomeInfo(name: "MN908947", length: 29_903, offset: 0, lineBases: 70, lineWidth: 71)
        ]

        let (aliasMap, notes) = SequenceViewerView.buildVariantChromosomeAliasMapWithLengthMatchNotes(
            bundleChromosomes: bundleChromosomes,
            variantDB: db,
            sequenceViewerLogger: logger,
            includeMaxPositionFallback: true
        )

        XCTAssertEqual(aliasMap["MN908947"], "MN908947.3")
        XCTAssertTrue(notes.isEmpty, "A name-based match must not produce a length-match note: \(notes)")
    }

    /// `buildVariantChromosomeAliasMap` (the plain alias-map-only entry point
    /// still used elsewhere) must return the identical map as the
    /// notes-returning variant -- this is a pure additive change, not a
    /// behavior change.
    func testPlainAliasMapEntryPointMatchesNotesVariant() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try makeDatabase(chromosome: "totally_different_name", position: 950, contigLength: nil, directory: dir)
        let bundleChromosomes = [
            ChromosomeInfo(name: "scaffold_1", length: 1000, offset: 0, lineBases: 70, lineWidth: 71)
        ]

        let plainAliasMap = SequenceViewerView.buildVariantChromosomeAliasMap(
            bundleChromosomes: bundleChromosomes,
            variantDB: db,
            sequenceViewerLogger: logger,
            includeMaxPositionFallback: true
        )
        let (aliasMapWithNotes, _) = SequenceViewerView.buildVariantChromosomeAliasMapWithLengthMatchNotes(
            bundleChromosomes: bundleChromosomes,
            variantDB: db,
            sequenceViewerLogger: logger,
            includeMaxPositionFallback: true
        )

        XCTAssertEqual(plainAliasMap, aliasMapWithNotes)
    }

    /// Setting length-match notes on the drawer must set a non-nil tooltip on
    /// the "Variants" tab segment containing the note text.
    func testDrawerSurfacesLengthMatchNoteAsVariantsTabTooltip() {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        let note = "Matched VCF contig totally_different_name to scaffold_1 by length"

        drawer.variantChromosomeLengthMatchNotes = [note]

        let tooltip = drawer.tabControl.toolTip(forSegment: AnnotationTableDrawerView.DrawerTab.variants.rawValue)
        XCTAssertEqual(tooltip, note)
    }

    /// Clearing the notes (e.g. after loading a bundle where every VCF contig
    /// matched by name) must clear the tooltip -- the drawer must not show a
    /// stale warning from a previously loaded bundle.
    func testDrawerClearsVariantsTabTooltipWhenNoLengthMatch() {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        drawer.variantChromosomeLengthMatchNotes = ["Matched VCF contig X to Y by length"]
        XCTAssertNotNil(drawer.tabControl.toolTip(forSegment: AnnotationTableDrawerView.DrawerTab.variants.rawValue))

        drawer.variantChromosomeLengthMatchNotes = []

        XCTAssertNil(drawer.tabControl.toolTip(forSegment: AnnotationTableDrawerView.DrawerTab.variants.rawValue))
    }
}
