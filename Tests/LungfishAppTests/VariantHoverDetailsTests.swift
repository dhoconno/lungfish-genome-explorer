// VariantHoverDetailsTests.swift - Variant hover detail and copy regressions
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

@MainActor
final class VariantHoverDetailsTests: XCTestCase {
    private var retainedViewerControllers: [ViewerViewController] = []

    override func tearDown() async throws {
        retainedViewerControllers.removeAll()
        try await super.tearDown()
    }

    func testFormatterIncludesInfoEffectCoordinatesTypeAndTrackIdentity() {
        let row = makeSearchResult(
            name: "rsFixture",
            chromosome: "chr7",
            start: 99,
            trackId: "track-a",
            trackName: "ignored by static formatter",
            type: "SNP",
            ref: "A",
            alt: "G",
            quality: 99.5,
            filter: "PASS"
        )

        let details = SequenceViewerView.formatVariantDetails(
            row: row,
            trackName: "Tumor calls",
            info: [
                "DP": "37",
                "AF": "0.25",
                "CSQ_Consequence": "missense_variant",
                "CSQ_HGVSp": "p.Gly12Asp",
            ]
        )

        XCTAssertEqual(details, """
        chr7:100  A → G
        ID: rsFixture
        Track: Tumor calls
        Track ID: track-a
        Variant type: SNP
        Depth (INFO/DP): 37
        Allele frequency (INFO/AF): 0.25
        Quality: 99.5
        Filter: PASS
        Consequence: missense_variant
        Amino acid change: p.Gly12Asp
        """)
    }

    func testFormatterHandlesFormatDepthDerivedFrequencyZeroAndMissingValues() {
        let row = makeSearchResult(name: ".", start: 9, trackId: "track-a")
        let genotypes = [
            makeGenotype(sample: "derived", depth: 12, alleleDepths: "8,4"),
            makeGenotype(sample: "zero-depth", depth: 0, alleleDepths: "0,0"),
            makeGenotype(sample: "missing", depth: nil, alleleDepths: nil),
            makeGenotype(sample: "explicit-zero", depth: 0, alleleDepths: nil, rawFields: "AF=0"),
        ]

        let details = SequenceViewerView.formatVariantDetails(
            row: row,
            trackName: "Calls",
            info: [:],
            genotypes: genotypes
        )

        XCTAssertTrue(details.contains("Sample: derived\n  Genotype: 0/1\n  Depth (FORMAT/DP): 12\n  Allele frequency (from AD): 0.333333\n  Allele depths (AD): 8,4"))
        XCTAssertTrue(details.contains("Sample: zero-depth\n  Genotype: 0/1\n  Depth (FORMAT/DP): 0\n  Allele depths (AD): 0,0"))
        XCTAssertTrue(details.contains("Sample: missing\n  Genotype: 0/1\n  Depth (FORMAT/DP): Not recorded"))
        XCTAssertTrue(details.contains("Sample: explicit-zero\n  Genotype: 0/1\n  Depth (FORMAT/DP): 0\n  Allele frequency (FORMAT): 0"))
        XCTAssertEqual(details.components(separatedBy: "Allele frequency (from AD):").count - 1, 1)
        XCTAssertFalse(details.lowercased().contains(": nan"))
        XCTAssertFalse(details.lowercased().contains(": inf"))
    }

    func testCopyVariantDetailsWritesOnlyToProvidedPasteboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        SequenceViewerView.copyVariantDetails("chr2:41  C → T", to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "chr2:41  C → T")
    }

    func testVariantContextMenuCarriesRichDetailsPayload() throws {
        let viewer = makeViewer()
        let row = makeSearchResult(
            name: "rsMenu",
            chromosome: "chr1",
            start: 120,
            trackId: "track-menu",
            trackName: "Menu calls",
            type: "DEL",
            ref: "AT",
            alt: "A",
            quality: 42,
            filter: "PASS",
            infoDict: ["DP": "18", "AF": "0.125", "ANN_Consequence": "frameshift_variant"]
        )

        let menu = viewer.testBuildContextMenu(for: .variant(row), genomicPosition: 120)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Copy Variant Details" })
        let payload = try XCTUnwrap(item.representedObject as? String)

        XCTAssertEqual(item.action, #selector(SequenceViewerView.copyVariantDetailsAction(_:)))
        XCTAssertTrue(item.target === viewer)
        XCTAssertTrue(payload.contains("chr1:121  AT → A"))
        XCTAssertTrue(payload.contains("ID: rsMenu"))
        XCTAssertTrue(payload.contains("Track: Menu calls"))
        XCTAssertTrue(payload.contains("Track ID: track-menu"))
        XCTAssertTrue(payload.contains("Variant type: DEL"))
        XCTAssertTrue(payload.contains("Depth (INFO/DP): 18"))
        XCTAssertTrue(payload.contains("Allele frequency (INFO/AF): 0.125"))
        XCTAssertTrue(payload.contains("Consequence: frameshift_variant"))
    }

    func testSummaryHitWithNoSamplesIncludesOverlappingVariantsFromBothTracksAndExcludesReadArea() throws {
        let viewer = makeViewer()
        viewer.cachedSampleCount = 0
        viewer.cachedVariantAnnotations = [
            makeVariantAnnotation(name: "variant-a", position: 240, trackId: "track-a", rowId: 1),
            makeVariantAnnotation(name: "variant-b", position: 240, trackId: "track-b", rowId: 2),
        ]

        let summaryPoint = NSPoint(
            x: 240,
            y: viewer.variantTrackY + viewer.effectiveSummaryBarHeight / 2
        )
        let hits = viewer.variantAnnotationsAtPoint(summaryPoint)
        let details = try XCTUnwrap(viewer.variantSummaryDetails(at: summaryPoint))

        XCTAssertEqual(
            Set(hits.compactMap { $0.qualifier("variant_track_id") }),
            Set(["track-a", "track-b"])
        )
        XCTAssertTrue(details.contains("ID: variant-a"))
        XCTAssertTrue(details.contains("Track ID: track-a"))
        XCTAssertTrue(details.contains("ID: variant-b"))
        XCTAssertTrue(details.contains("Track ID: track-b"))
        XCTAssertEqual(details.components(separatedBy: "Variant type: SNP").count - 1, 2)

        let readAreaPoint = NSPoint(
            x: summaryPoint.x,
            y: viewer.variantTrackY
                + viewer.effectiveSummaryBarHeight
                + viewer.effectiveSummaryToRowGap
                + viewer.sampleDisplayState.rowHeight
                + 1
        )
        XCTAssertTrue(viewer.variantAnnotationsAtPoint(readAreaPoint).isEmpty)
        XCTAssertNil(viewer.variantSummaryDetails(at: readAreaPoint))
    }

    private func makeViewer() -> SequenceViewerView {
        let controller = ViewerViewController()
        controller.loadView()
        controller.viewerView.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        controller.referenceFrame = ReferenceFrame(
            chromosome: "chr1",
            start: 0,
            end: 800,
            pixelWidth: 800,
            sequenceLength: 10_000
        )
        retainedViewerControllers.append(controller)
        return controller.viewerView
    }

    private func makeSearchResult(
        name: String,
        chromosome: String = "chr1",
        start: Int,
        trackId: String,
        trackName: String? = nil,
        type: String = "SNP",
        ref: String = "A",
        alt: String = "G",
        quality: Double? = nil,
        filter: String? = nil,
        infoDict: [String: String]? = nil
    ) -> AnnotationSearchIndex.SearchResult {
        AnnotationSearchIndex.SearchResult(
            name: name,
            chromosome: chromosome,
            start: start,
            end: start + max(1, ref.count),
            trackId: trackId,
            trackName: trackName,
            type: type,
            strand: ".",
            ref: ref,
            alt: alt,
            quality: quality,
            filter: filter,
            sampleCount: 0,
            variantRowId: nil,
            infoDict: infoDict
        )
    }

    private func makeGenotype(
        sample: String,
        depth: Int?,
        alleleDepths: String?,
        rawFields: String? = nil
    ) -> GenotypeRecord {
        GenotypeRecord(
            variantRowId: 1,
            sampleName: sample,
            genotype: "0/1",
            allele1: 0,
            allele2: 1,
            isPhased: false,
            depth: depth,
            genotypeQuality: nil,
            alleleDepths: alleleDepths,
            rawFields: rawFields
        )
    }

    private func makeVariantAnnotation(
        name: String,
        position: Int,
        trackId: String,
        rowId: Int64
    ) -> SequenceAnnotation {
        SequenceAnnotation(
            type: .snp,
            name: name,
            chromosome: "chr1",
            start: position,
            end: position + 1,
            qualifiers: [
                "variant_track_id": AnnotationQualifier(trackId),
                "variant_row_id": AnnotationQualifier(String(rowId)),
                "variant_type": AnnotationQualifier("SNP"),
                "ref": AnnotationQualifier("A"),
                "alt": AnnotationQualifier("G"),
                "sample_count": AnnotationQualifier("0"),
            ]
        )
    }
}
