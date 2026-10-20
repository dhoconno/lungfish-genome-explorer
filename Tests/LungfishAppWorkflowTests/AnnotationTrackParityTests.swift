// AnnotationTrackParityTests.swift - The figure's annotation packing against the live view
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishWorkflow

/// `ViewerFigureAnnotationPacking` copies the live packing and label rules. These cases run both
/// on the annotations `AnnotationPackingPinTests` pinned and require the same rows, overflow,
/// track order and labels, through the frame conversion the live draw uses.
@MainActor
final class AnnotationTrackParityTests: XCTestCase {
    private typealias Fixture = AnnotationPackingFixture
    private typealias Packing = ViewerFigureAnnotationPacking

    private func frames(width: Int = 1_000) -> (live: ReferenceFrame, figure: ViewerFigureFrame) {
        let live = ReferenceFrame(chromosome: Fixture.chromosome, start: 0, end: 1_000, pixelWidth: width, sequenceLength: 1_000)
        return (live, live.figureFrame)
    }

    private func viewer() -> SequenceViewerView {
        SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 300))
    }

    func testLayeredPackingAndTrackOrderEqualTheLiveView() {
        let view = viewer()
        let (live, figure) = frames()
        for annotations in [Fixture.all, Fixture.genes + Fixture.repeats, Fixture.genes, Fixture.repeats] {
            let expected = view.packAnnotationsLayered(annotations, frame: live)
            let packed = Packing.packLayered(annotations, frame: figure, maxRows: view.maxAnnotationRows)
            XCTAssertEqual(Fixture.names(packed.rows), Fixture.names(expected.rows))
            XCTAssertEqual(packed.overflow, expected.overflow)
            XCTAssertEqual(Packing.orderedTrackIDs(for: annotations), view.orderedAnnotationTrackIDs(for: annotations))
        }
    }

    func testRowCapAndPixelPackingEqualTheLiveView() {
        let view = viewer()
        for width in [1_000, 100, 37] {
            let (live, figure) = frames(width: width)
            for maxRows in 0...3 {
                let expected = view.packAnnotationsLayeredWithinTrack(Fixture.genes, frame: live, maxRows: maxRows)
                let packed = Packing.packWithinTrack(Fixture.genes, frame: figure, maxRows: maxRows)
                XCTAssertEqual(Fixture.names(packed.rows), Fixture.names(expected.rows), "width \(width) rows \(maxRows)")
                XCTAssertEqual(packed.overflow, expected.overflow, "width \(width) rows \(maxRows)")
                let pixel = Packing.packPixelBased(Fixture.all, frame: figure, maxRows: maxRows)
                let livePixel = view.packAnnotationsPixelBased(Fixture.all, frame: live, maxRows: maxRows)
                XCTAssertEqual(Fixture.names(pixel.rows), Fixture.names(livePixel.rows), "width \(width) rows \(maxRows)")
                XCTAssertEqual(pixel.overflow, livePixel.overflow, "width \(width) rows \(maxRows)")
            }
        }
    }

    func testLabelRulesAndConstantsEqualTheLiveView() {
        let view = viewer()
        XCTAssertEqual(Packing.minPixelGap, view.minPixelGap)
        XCTAssertEqual(Packing.minExpandedLabelWidth, view.minExpandedLabelWidth)
        XCTAssertEqual(Packing.maxLabeledRows, view.maxLabeledRows)
        let odd = [
            Fixture.annotation("  two\n  words\t", .gene, 0, 10, track: "genes"),
            Fixture.annotation(" \r\n", .cds, 0, 10, track: "genes"),
        ]
        for annotation in Fixture.all + odd {
            XCTAssertEqual(Packing.displayLabel(for: annotation), view.displayLabel(for: annotation))
            for width: CGFloat in [3, 71.9, 72, 400] {
                for rows in [1, 12, 13] {
                    XCTAssertEqual(
                        Packing.shouldRenderExpandedLabel(for: annotation, width: width, rowCount: rows),
                        view.shouldRenderExpandedLabel(for: annotation, width: width, rowCount: rows),
                        "\(annotation.name) width \(width) rows \(rows)"
                    )
                }
            }
        }
        for type in AnnotationType.allCases {
            XCTAssertEqual(Packing.isVariant(type), view.isVariantAnnotationType(type), type.rawValue)
        }
    }
}
