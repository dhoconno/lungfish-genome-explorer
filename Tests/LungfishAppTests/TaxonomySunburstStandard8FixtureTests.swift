// TaxonomySunburstStandard8FixtureTests.swift - Sunburst regressions on a real Standard-8 kreport
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Uses Tests/Fixtures/kraken2-standard8-trimmed, a trimmed report from a run
// that is 99.28% unclassified, uses non-canonical rank codes throughout, and
// nests one lineage 31 levels deep. Every check compares the layout against
// the report's own clade counts.

import AppKit
import XCTest
@testable import LungfishApp
import LungfishIO

@MainActor
final class TaxonomySunburstStandard8FixtureTests: XCTestCase {

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // LungfishAppTests
        .deletingLastPathComponent()  // Tests
        .appendingPathComponent("Fixtures/kraken2-standard8-trimmed/classification.kreport")

    private let bounds = CGRect(x: 0, y: 0, width: 900, height: 900)

    private func loadTree() throws -> TaxonTree {
        try KreportParser.parse(url: Self.fixtureURL)
    }

    // MARK: - Report truth

    func testFixtureMatchesReportHeadline() throws {
        let tree = try loadTree()
        XCTAssertEqual(tree.totalReads, 11_284_830)
        XCTAssertEqual(tree.unclassifiedReads, 11_203_859)
        XCTAssertEqual(tree.classifiedReads, 80_971)
        XCTAssertEqual(tree.root.readsDirect, 833)
        // Every node's clade count is direct + children, as kraken2 guarantees.
        for node in tree.allNodes() {
            let childSum = node.children.reduce(0) { $0 + $1.readsClade }
            XCTAssertEqual(node.readsClade, node.readsDirect + childSum, node.name)
        }
    }

    // MARK: - Angles are shares of the classified tree

    func testWedgeAnglesAreCladeSharesOfClassifiedReads() throws {
        let tree = try loadTree()
        let layout = SunburstLayout(tree: tree, bounds: bounds)
        let segments = layout.computeSegments()
        let drawn = segments.filter { !$0.isOther }
        XCTAssertFalse(drawn.isEmpty)

        for segment in drawn {
            let expected = CGFloat(segment.node.readsClade) / CGFloat(tree.classifiedReads) * 360
            XCTAssertEqual(segment.angularSpanDegrees, expected, accuracy: 1e-9, segment.node.name)
        }

        func span(_ taxId: Int) -> CGFloat? {
            drawn.first { $0.node.taxId == taxId }?.angularSpanDegrees
        }
        XCTAssertEqual(try XCTUnwrap(span(131567)), 79_216.0 / 80_971 * 360, accuracy: 1e-9)  // cellular organisms
        XCTAssertEqual(try XCTUnwrap(span(2)), 74_246.0 / 80_971 * 360, accuracy: 1e-9)       // Bacteria
        XCTAssertEqual(try XCTUnwrap(span(2759)), 4_121.0 / 80_971 * 360, accuracy: 1e-9)     // Eukaryota
        XCTAssertEqual(try XCTUnwrap(span(10239)), 922.0 / 80_971 * 360, accuracy: 1e-9)      // Viruses
    }

    // MARK: - Nesting and ring placement by tree depth

    func testChildrenNestInsideParentsOneRingOut() throws {
        let tree = try loadTree()
        let layout = SunburstLayout(tree: tree, bounds: bounds)
        let segments = layout.computeSegments()
        var byNode: [ObjectIdentifier: SunburstSegment] = [:]
        for segment in segments where !segment.isOther {
            byNode[ObjectIdentifier(segment.node)] = segment
        }

        for segment in segments {
            guard let parent = segment.isOther
                ? tree.node(taxId: segment.node.taxId)
                : segment.node.parent else { continue }
            if parent === tree.root {
                XCTAssertEqual(segment.ring, 0, segment.node.name)
                continue
            }
            let parentSegment = try XCTUnwrap(byNode[ObjectIdentifier(parent)], "\(segment.node.name) drawn without its parent")
            XCTAssertEqual(segment.ring, parentSegment.ring + 1, segment.node.name)
            XCTAssertGreaterThanOrEqual(segment.startAngle, parentSegment.startAngle - 1e-9, segment.node.name)
            XCTAssertLessThanOrEqual(segment.endAngle, parentSegment.endAngle + 1e-9, segment.node.name)
        }

        // Non-canonical ranks sit at their tree depth: the human lineage is a
        // contiguous column from Eukaryota (ring 1) out to the last ring.
        let lineage = [2759, 33154, 33208, 6072, 33213, 33511, 7711]
        for (offset, taxId) in lineage.enumerated() {
            let segment = try XCTUnwrap(byNode[ObjectIdentifier(try XCTUnwrap(tree.node(taxId: taxId)))])
            XCTAssertEqual(segment.ring, 1 + offset, "taxId \(taxId)")
            XCTAssertEqual(segment.angularSpanDegrees, 4_121.0 / 80_971 * 360, accuracy: 1e-9)
        }
        XCTAssertEqual(try XCTUnwrap(tree.node(taxId: 33208)).rank, .kingdom)
        XCTAssertEqual(try XCTUnwrap(tree.node(taxId: 33154)).rank, .intermediate("D1"))
    }

    // MARK: - Mass conservation with tiny taxa

    func testTinyTaxaArePooledIntoTheirParentsWedge() throws {
        let tree = try loadTree()
        let layout = SunburstLayout(tree: tree, bounds: bounds)
        let segments = layout.computeSegments()

        // Archaea (69 of 80,971 reads) is below the drawing threshold, so it is
        // not drawn on its own but its reads are pooled under cellular organisms.
        XCTAssertNil(segments.first { !$0.isOther && $0.node.taxId == 2157 })
        let pooled = try XCTUnwrap(segments.first { $0.isOther && $0.node.taxId == 131567 })
        XCTAssertEqual(pooled.ring, 1)
        XCTAssertEqual(pooled.node.readsClade, 69)
        XCTAssertEqual(pooled.node.rank, TaxonomicRank(code: SunburstLayout.aggregateRankCode))
        XCTAssertEqual(pooled.node.name, "1 smaller taxon under cellular organisms")
        XCTAssertEqual(pooled.angularSpanDegrees, 69.0 / 80_971 * 360, accuracy: 1e-9)

        // For every drawn parent: drawn children + pooled wedge + direct gap = clade.
        var childrenSpan: [Int: CGFloat] = [:]
        for segment in segments {
            let parentTaxId = segment.isOther ? segment.node.taxId : segment.node.parent?.taxId
            guard let parentTaxId else { continue }
            childrenSpan[parentTaxId, default: 0] += segment.angularSpanDegrees
        }
        for segment in segments where !segment.isOther {
            let node = segment.node
            guard node.children.contains(where: { $0.readsClade > 0 }), segment.ring + 1 < layout.maxRings else { continue }
            let expectedChildren = CGFloat(node.readsClade - node.readsDirect) / CGFloat(tree.classifiedReads) * 360
            XCTAssertEqual(childrenSpan[node.taxId] ?? 0, expectedChildren, accuracy: 1e-9, node.name)
        }
    }

    // MARK: - Denominators are named

    func testCenterLabelNamesItsDenominator() throws {
        let tree = try loadTree()
        XCTAssertEqual(
            TaxonomySunburstView.centerPercentText(for: tree.root, isZoomed: false, tree: tree),
            "0.72% of all reads"
        )
        let eukaryota = try XCTUnwrap(tree.node(taxId: 2759))
        XCTAssertEqual(
            TaxonomySunburstView.centerPercentText(for: eukaryota, isZoomed: true, tree: tree),
            "5.1% of classified"
        )
    }

    func testPercentFormatKeepsSmallSharesVisible() {
        XCTAssertEqual(TaxonomyPercentFormat.string(fraction: 4_121.0 / 11_284_830), "0.04%")
        XCTAssertEqual(TaxonomyPercentFormat.string(fraction: 69.0 / 11_284_830), "<0.01%")
        XCTAssertEqual(TaxonomyPercentFormat.string(fraction: 0.717), "71.7%")
        XCTAssertEqual(TaxonomyPercentFormat.string(fraction: 0), "0%")
    }

    func testTooltipShowsBothDenominatorsForAggregateWedge() throws {
        let tree = try loadTree()
        let layout = SunburstLayout(tree: tree, bounds: bounds)
        let pooled = try XCTUnwrap(layout.computeSegments().first { $0.isOther && $0.node.taxId == 131567 })
        let tooltip = TaxonomyTooltipView(frame: .zero)
        tooltip.update(with: pooled.node, totalReads: tree.totalReads, classifiedReads: tree.classifiedReads)
        XCTAssertEqual(tooltip.percentOfTotal, 69.0 / 11_284_830 * 100, accuracy: 1e-9)
        XCTAssertEqual(tooltip.percentOfClassified, 69.0 / 80_971 * 100, accuracy: 1e-9)
    }

    // MARK: - Interaction

    func testHoverReachesAggregateWedgeButZoomDoesNot() throws {
        let tree = try loadTree()
        let view = TaxonomySunburstView(frame: bounds)
        view.tree = tree
        let layout = SunburstLayout(tree: tree, bounds: bounds)
        let pooled = try XCTUnwrap(layout.computeSegments().first { $0.isOther && $0.node.taxId == 131567 })
        let location = NSPoint(
            x: layout.center.x + pooled.midRadius * sin(pooled.midAngle),
            y: layout.center.y - pooled.midRadius * cos(pooled.midAngle)
        )
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        let windowLocation = view.convert(location, to: nil)
        func event(_ type: NSEvent.EventType, clicks: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: windowLocation, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: clicks, pressure: 0))
        }
        view.mouseMoved(with: try event(.mouseMoved, clicks: 0))
        // The view lays out its own aggregate node, so compare by content.
        let hovered = try XCTUnwrap(view.hoveredNode)
        XCTAssertEqual(hovered.name, pooled.node.name)
        XCTAssertEqual(hovered.readsClade, 69)
        XCTAssertEqual(hovered.rank, TaxonomicRank(code: SunburstLayout.aggregateRankCode))

        view.mouseDown(with: try event(.leftMouseDown, clicks: 2))
        XCTAssertNil(view.centerNode, "double-clicking a pooled wedge must not re-root the chart")
        XCTAssertNil(view.selectedNode)
    }

    func testZoomReRootsOnTheChosenNode() throws {
        let tree = try loadTree()
        let view = TaxonomySunburstView(frame: bounds)
        view.tree = tree
        let eukaryota = try XCTUnwrap(tree.node(taxId: 2759))
        view.centerNode = eukaryota
        let layout = SunburstLayout(tree: tree, zoomRoot: eukaryota, bounds: bounds)
        let segments = layout.computeSegments()
        // Single-child lineage: every ring is one full turn from Opisthokonta outward.
        XCTAssertEqual(segments.count, layout.maxRings)
        for (ring, segment) in segments.enumerated() {
            XCTAssertEqual(segment.ring, ring)
            XCTAssertEqual(segment.angularSpanDegrees, 360, accuracy: 1e-9, segment.node.name)
        }
        XCTAssertEqual(segments.first?.node.taxId, 33154)
    }

    // MARK: - Rendered diagnostic

    func testRenderedFixtureDiagnostic() throws {
        let tree = try loadTree()
        let view = TaxonomySunburstView(frame: bounds)
        view.tree = tree
        view.appearance = NSAppearance(named: .aqua)

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 1800,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/krona-qa", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("standard8-trimmed.png"))
        XCTAssertFalse(png.isEmpty)
    }
}
