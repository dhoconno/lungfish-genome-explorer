// BundleTrackListingAndProgressTests.swift - `bundle info` / `bundle list` show alignment tracks; `map` progress is line-oriented off a TTY
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishCore

final class BundleTrackListingAndProgressTests: XCTestCase {
    private var manifest: BundleManifest {
        BundleManifest(
            name: "Fixture",
            identifier: "test.fixture",
            source: SourceInfo(organism: "Test", assembly: "TestAssembly", database: "Fixture"),
            alignments: [
                AlignmentTrackInfo(
                    id: "aln_1",
                    name: "Sample A reads",
                    sourcePath: "alignments/aln_1.sorted.bam",
                    indexPath: "alignments/aln_1.sorted.bam.bai",
                    mappedReadCount: 12_345
                ),
                AlignmentTrackInfo(
                    id: "aln_2",
                    name: "Sample B reads",
                    format: .cram,
                    sourcePath: "alignments/aln_2.cram",
                    indexPath: "alignments/aln_2.cram.crai"
                ),
            ]
        )
    }

    func testBundleInfoTableListsAlignmentTracks() {
        let formatter = TerminalFormatter(useColors: false)
        XCTAssertEqual(BundleAlignmentTrackListing.tableHeaders, ["ID", "Name", "Format", "Mapped Reads", "Path"])
        XCTAssertEqual(
            BundleAlignmentTrackListing.tableRows(manifest.alignments, formatter: formatter),
            [
                ["aln_1", "Sample A reads", "bam", formatter.number(12_345), "alignments/aln_1.sorted.bam"],
                ["aln_2", "Sample B reads", "cram", "-", "alignments/aln_2.cram"],
            ]
        )
    }

    func testBundleListLinesAndJSONListAlignmentTracks() throws {
        let formatter = TerminalFormatter(useColors: false)
        XCTAssertEqual(
            BundleAlignmentTrackListing.listLines(manifest.alignments, formatter: formatter),
            [
                "aln_1: Sample A reads (bam, \(formatter.number(12_345)) mapped reads) alignments/aln_1.sorted.bam",
                "aln_2: Sample B reads (cram) alignments/aln_2.cram",
            ]
        )

        let data = try JSONEncoder().encode(BundleTrackList(manifest: manifest))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["alignments"] as? [String], ["aln_1", "aln_2"])
        XCTAssertEqual(object["annotations"] as? [String], [])
    }

    func testMapProgressIsOneLinePerUpdateOffATerminal() {
        XCTAssertEqual(MapProgressLine.render("Mapping reads", isTerminal: true), "\rMapping reads")
        XCTAssertEqual(MapProgressLine.render("Mapping reads", isTerminal: false), "Mapping reads\n")
    }
}
