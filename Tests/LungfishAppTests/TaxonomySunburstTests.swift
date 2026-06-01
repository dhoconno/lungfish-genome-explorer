// TaxonomySunburstTests.swift - Tests for sunburst chart geometry, palette, and table
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit

// MARK: - Test Helpers

/// Builds a minimal taxonomy tree for testing.
///
/// Structure:
/// ```
/// root (taxId: 1, clade: 10000)
///   +-- Bacteria (taxId: 2, domain, clade: 8000, direct: 100)
///   |     +-- Proteobacteria (taxId: 1224, phylum, clade: 5000, direct: 50)
///   |     |     +-- Gammaproteobacteria (taxId: 1236, class, clade: 3000, direct: 30)
///   |     |     |     +-- Enterobacterales (taxId: 91347, order, clade: 2000, direct: 20)
///   |     |     |     |     +-- Enterobacteriaceae (taxId: 543, family, clade: 1500, direct: 10)
///   |     |     |     |     |     +-- Escherichia (taxId: 561, genus, clade: 1200, direct: 50)
///   |     |     |     |     |     |     +-- E. coli (taxId: 562, species, clade: 1000, direct: 1000)
///   |     |     |     |     |     |     +-- E. fergusonii (taxId: 564, species, clade: 200, direct: 200)
///   |     |     |     |     |     +-- Klebsiella (taxId: 570, genus, clade: 300, direct: 300)
///   |     |     |     |     +-- Yersiniaceae (taxId: 1903411, family, clade: 500, direct: 500)
///   |     |     |     +-- Pseudomonadales (taxId: 72274, order, clade: 1000, direct: 1000)
///   |     |     +-- Alphaproteobacteria (taxId: 28211, class, clade: 2000, direct: 2000)
///   |     +-- Firmicutes (taxId: 1239, phylum, clade: 2000, direct: 50)
///   |     |     +-- Bacilli (taxId: 91061, class, clade: 2000, direct: 2000)
///   |     +-- Actinobacteria (taxId: 201174, phylum, clade: 1000, direct: 1000)
///   +-- Archaea (taxId: 2157, domain, clade: 2000, direct: 2000)
/// ```
@MainActor
private func makeTestTree() -> TaxonTree {
    let root = TaxonNode(
        taxId: 1, name: "root", rank: .root, depth: 0,
        readsDirect: 0, readsClade: 10000, fractionClade: 1.0, fractionDirect: 0.0,
        parentTaxId: nil
    )

    let bacteria = TaxonNode(
        taxId: 2, name: "Bacteria", rank: .domain, depth: 1,
        readsDirect: 100, readsClade: 8000, fractionClade: 0.8, fractionDirect: 0.01,
        parentTaxId: 1
    )
    bacteria.parent = root
    root.children = [bacteria]

    let archaea = TaxonNode(
        taxId: 2157, name: "Archaea", rank: .domain, depth: 1,
        readsDirect: 2000, readsClade: 2000, fractionClade: 0.2, fractionDirect: 0.2,
        parentTaxId: 1
    )
    archaea.parent = root
    root.children.append(archaea)

    let proteobacteria = TaxonNode(
        taxId: 1224, name: "Proteobacteria", rank: .phylum, depth: 2,
        readsDirect: 50, readsClade: 5000, fractionClade: 0.5, fractionDirect: 0.005,
        parentTaxId: 2
    )
    proteobacteria.parent = bacteria

    let firmicutes = TaxonNode(
        taxId: 1239, name: "Firmicutes", rank: .phylum, depth: 2,
        readsDirect: 50, readsClade: 2000, fractionClade: 0.2, fractionDirect: 0.005,
        parentTaxId: 2
    )
    firmicutes.parent = bacteria

    let actinobacteria = TaxonNode(
        taxId: 201174, name: "Actinobacteria", rank: .phylum, depth: 2,
        readsDirect: 1000, readsClade: 1000, fractionClade: 0.1, fractionDirect: 0.1,
        parentTaxId: 2
    )
    actinobacteria.parent = bacteria

    bacteria.children = [proteobacteria, firmicutes, actinobacteria]

    let gamma = TaxonNode(
        taxId: 1236, name: "Gammaproteobacteria", rank: .class, depth: 3,
        readsDirect: 30, readsClade: 3000, fractionClade: 0.3, fractionDirect: 0.003,
        parentTaxId: 1224
    )
    gamma.parent = proteobacteria

    let alpha = TaxonNode(
        taxId: 28211, name: "Alphaproteobacteria", rank: .class, depth: 3,
        readsDirect: 2000, readsClade: 2000, fractionClade: 0.2, fractionDirect: 0.2,
        parentTaxId: 1224
    )
    alpha.parent = proteobacteria

    proteobacteria.children = [gamma, alpha]

    let enterobacterales = TaxonNode(
        taxId: 91347, name: "Enterobacterales", rank: .order, depth: 4,
        readsDirect: 20, readsClade: 2000, fractionClade: 0.2, fractionDirect: 0.002,
        parentTaxId: 1236
    )
    enterobacterales.parent = gamma

    let pseudomonadales = TaxonNode(
        taxId: 72274, name: "Pseudomonadales", rank: .order, depth: 4,
        readsDirect: 1000, readsClade: 1000, fractionClade: 0.1, fractionDirect: 0.1,
        parentTaxId: 1236
    )
    pseudomonadales.parent = gamma

    gamma.children = [enterobacterales, pseudomonadales]

    let enterobacteriaceae = TaxonNode(
        taxId: 543, name: "Enterobacteriaceae", rank: .family, depth: 5,
        readsDirect: 10, readsClade: 1500, fractionClade: 0.15, fractionDirect: 0.001,
        parentTaxId: 91347
    )
    enterobacteriaceae.parent = enterobacterales

    let yersiniaceae = TaxonNode(
        taxId: 1903411, name: "Yersiniaceae", rank: .family, depth: 5,
        readsDirect: 500, readsClade: 500, fractionClade: 0.05, fractionDirect: 0.05,
        parentTaxId: 91347
    )
    yersiniaceae.parent = enterobacterales

    enterobacterales.children = [enterobacteriaceae, yersiniaceae]

    let escherichia = TaxonNode(
        taxId: 561, name: "Escherichia", rank: .genus, depth: 6,
        readsDirect: 50, readsClade: 1200, fractionClade: 0.12, fractionDirect: 0.005,
        parentTaxId: 543
    )
    escherichia.parent = enterobacteriaceae

    let klebsiella = TaxonNode(
        taxId: 570, name: "Klebsiella", rank: .genus, depth: 6,
        readsDirect: 300, readsClade: 300, fractionClade: 0.03, fractionDirect: 0.03,
        parentTaxId: 543
    )
    klebsiella.parent = enterobacteriaceae

    enterobacteriaceae.children = [escherichia, klebsiella]

    let ecoli = TaxonNode(
        taxId: 562, name: "Escherichia coli", rank: .species, depth: 7,
        readsDirect: 1000, readsClade: 1000, fractionClade: 0.1, fractionDirect: 0.1,
        parentTaxId: 561
    )
    ecoli.parent = escherichia

    let efergusonii = TaxonNode(
        taxId: 564, name: "Escherichia fergusonii", rank: .species, depth: 7,
        readsDirect: 200, readsClade: 200, fractionClade: 0.02, fractionDirect: 0.02,
        parentTaxId: 561
    )
    efergusonii.parent = escherichia

    escherichia.children = [ecoli, efergusonii]

    let bacilli = TaxonNode(
        taxId: 91061, name: "Bacilli", rank: .class, depth: 3,
        readsDirect: 2000, readsClade: 2000, fractionClade: 0.2, fractionDirect: 0.2,
        parentTaxId: 1239
    )
    bacilli.parent = firmicutes
    firmicutes.children = [bacilli]

    return TaxonTree(root: root, unclassifiedNode: nil, totalReads: 10000)
}

/// Builds a tree with a single species (minimal case).
@MainActor
private func makeSingleSpeciesTree() -> TaxonTree {
    let root = TaxonNode(
        taxId: 1, name: "root", rank: .root, depth: 0,
        readsDirect: 0, readsClade: 100, fractionClade: 1.0, fractionDirect: 0.0,
        parentTaxId: nil
    )
    let bacteria = TaxonNode(
        taxId: 2, name: "Bacteria", rank: .domain, depth: 1,
        readsDirect: 0, readsClade: 100, fractionClade: 1.0, fractionDirect: 0.0,
        parentTaxId: 1
    )
    bacteria.parent = root
    root.children = [bacteria]

    let proteo = TaxonNode(
        taxId: 1224, name: "Proteobacteria", rank: .phylum, depth: 2,
        readsDirect: 0, readsClade: 100, fractionClade: 1.0, fractionDirect: 0.0,
        parentTaxId: 2
    )
    proteo.parent = bacteria
    bacteria.children = [proteo]

    let ecoli = TaxonNode(
        taxId: 562, name: "Escherichia coli", rank: .species, depth: 3,
        readsDirect: 100, readsClade: 100, fractionClade: 1.0, fractionDirect: 1.0,
        parentTaxId: 1224
    )
    ecoli.parent = proteo
    proteo.children = [ecoli]

    return TaxonTree(root: root, unclassifiedNode: nil, totalReads: 100)
}

/// Builds a tree with many species to test aggregation behavior.
@MainActor
private func makeManySpeciesTree(speciesCount: Int = 200) -> TaxonTree {
    let totalReads = speciesCount * 10
    let root = TaxonNode(
        taxId: 1, name: "root", rank: .root, depth: 0,
        readsDirect: 0, readsClade: totalReads, fractionClade: 1.0, fractionDirect: 0.0,
        parentTaxId: nil
    )
    let bacteria = TaxonNode(
        taxId: 2, name: "Bacteria", rank: .domain, depth: 1,
        readsDirect: 0, readsClade: totalReads, fractionClade: 1.0, fractionDirect: 0.0,
        parentTaxId: 1
    )
    bacteria.parent = root
    root.children = [bacteria]

    let proteo = TaxonNode(
        taxId: 1224, name: "Proteobacteria", rank: .phylum, depth: 2,
        readsDirect: 0, readsClade: totalReads, fractionClade: 1.0, fractionDirect: 0.0,
        parentTaxId: 2
    )
    proteo.parent = bacteria
    bacteria.children = [proteo]

    var species: [TaxonNode] = []
    for i in 0..<speciesCount {
        let sp = TaxonNode(
            taxId: 10000 + i, name: "Species_\(i)", rank: .species, depth: 3,
            readsDirect: 10, readsClade: 10,
            fractionClade: 10.0 / Double(totalReads),
            fractionDirect: 10.0 / Double(totalReads),
            parentTaxId: 1224
        )
        sp.parent = proteo
        species.append(sp)
    }
    proteo.children = species

    return TaxonTree(root: root, unclassifiedNode: nil, totalReads: totalReads)
}

/// Makes an empty tree (root with zero reads).
@MainActor
private func makeEmptyTree() -> TaxonTree {
    let root = TaxonNode(
        taxId: 1, name: "root", rank: .root, depth: 0,
        readsDirect: 0, readsClade: 0, fractionClade: 0.0, fractionDirect: 0.0,
        parentTaxId: nil
    )
    return TaxonTree(root: root, unclassifiedNode: nil, totalReads: 0)
}

// MARK: - SunburstGeometry Tests

@MainActor
final class SunburstGeometryTests: XCTestCase {

    // MARK: - Arc Segment Calculation

    func testArcSegmentCalculation() {
        let tree = makeTestTree()
        let layout = SunburstLayout(
            tree: tree,
            bounds: CGRect(x: 0, y: 0, width: 600, height: 600),
            maxRings: 8,
            minFractionToShow: 0.001
        )

        let segments = layout.computeSegments()
        XCTAssertFalse(segments.isEmpty, "Segments should not be empty for a valid tree")

        // Ring 0 segments should be the root's children (Bacteria and Archaea)
        let ring0 = segments.filter { $0.ring == 0 && !$0.isOther }
        XCTAssertEqual(ring0.count, 2, "Ring 0 should have 2 segments (Bacteria and Archaea)")

        // Angular spans at ring 0 should sum to approximately 2*pi
        let totalAngle = ring0.reduce(CGFloat(0)) { $0 + $1.angularSpan }
        XCTAssertEqual(totalAngle, 2 * .pi, accuracy: 0.01,
                       "Ring 0 angular spans should sum to 2*pi")

        // Bacteria (80%) should have ~80% of the angle
        let bacteriaSegment = ring0.first { $0.node.taxId == 2 }
        XCTAssertNotNil(bacteriaSegment)
        if let bSeg = bacteriaSegment {
            let expectedAngle = 2 * CGFloat.pi * 0.8
            XCTAssertEqual(bSeg.angularSpan, expectedAngle, accuracy: 0.01,
                           "Bacteria should occupy ~80% of the ring")
        }
    }

    func testChildSegmentsAnglesSumToParentAngle() {
        let tree = makeTestTree()
        let layout = SunburstLayout(
            tree: tree,
            bounds: CGRect(x: 0, y: 0, width: 600, height: 600),
            maxRings: 8,
            minFractionToShow: 0.001
        )

        let segments = layout.computeSegments()

        // Proteobacteria's children (Gamma + Alpha) should sum to Proteobacteria's span
        let proteoSegment = segments.first { $0.node.taxId == 1224 && !$0.isOther }
        let proteoChildren = segments.filter {
            ($0.node.taxId == 1236 || $0.node.taxId == 28211) && !$0.isOther
        }

        if let proteo = proteoSegment {
            let childrenAngle = proteoChildren.reduce(CGFloat(0)) { $0 + $1.angularSpan }
            XCTAssertEqual(childrenAngle, proteo.angularSpan, accuracy: 0.01,
                           "Children's angular spans should sum to parent's angular span")
        }
    }

    // MARK: - Hit Testing

    func testHitTestingCenter() {
        let tree = makeTestTree()
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
        let layout = SunburstLayout(tree: tree, bounds: bounds, maxRings: 8)
        let segments = layout.computeSegments()

        // Center point should return nil (it's the center circle)
        let centerPoint = NSPoint(x: 300, y: 300)
        let result = layout.hitTest(point: centerPoint, segments: segments)
        XCTAssertNil(result, "Hit testing the center should return nil")
        XCTAssertTrue(layout.isInCenter(point: centerPoint),
                      "Center point should be detected as in center")
    }

    func testHitTestingOuterRing() {
        let tree = makeTestTree()
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
        let layout = SunburstLayout(tree: tree, bounds: bounds, maxRings: 8)
        let segments = layout.computeSegments()

        // Find a segment in an outer ring and test a point in its region
        let outerSegments = segments.filter { $0.ring >= 2 && !$0.isOther }
        guard let testSegment = outerSegments.first else {
            // May not have outer ring segments with this tree structure
            return
        }

        let midR = testSegment.midRadius
        let midA = testSegment.midAngle

        // Convert polar to cartesian (flipped coords)
        let testPoint = NSPoint(
            x: layout.center.x + midR * sin(midA),
            y: layout.center.y - midR * cos(midA)
        )

        let result = layout.hitTest(point: testPoint, segments: segments)
        XCTAssertNotNil(result, "Hit testing a point inside a segment should return that segment")
        if let hit = result {
            XCTAssertEqual(hit.node.taxId, testSegment.node.taxId,
                           "Hit test should return the correct segment")
        }
    }

    func testHitTestingEmptySpace() {
        let tree = makeTestTree()
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
        let layout = SunburstLayout(tree: tree, bounds: bounds, maxRings: 8)
        let segments = layout.computeSegments()

        // Point well outside the chart
        let outsidePoint = NSPoint(x: 0, y: 0)
        let result = layout.hitTest(point: outsidePoint, segments: segments)
        XCTAssertNil(result, "Hit testing outside the chart should return nil")
    }

    func testHitTestFarOutsideReturnsNil() {
        let tree = makeTestTree()
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
        let layout = SunburstLayout(tree: tree, bounds: bounds, maxRings: 8)
        let segments = layout.computeSegments()

        // Way beyond the outer ring
        let farPoint = NSPoint(x: 1000, y: 1000)
        let result = layout.hitTest(point: farPoint, segments: segments)
        XCTAssertNil(result, "Hit testing far outside should return nil")
    }

    // MARK: - Geometry Dimensions

    func testCenterRadiusIs15Percent() {
        let tree = makeTestTree()
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
        let layout = SunburstLayout(tree: tree, bounds: bounds, maxRings: 8)

        let expectedAvailable = (600.0 / 2.0) - SunburstLayout.outerPadding
        let expectedCenter = expectedAvailable * SunburstLayout.centerRadiusFraction

        XCTAssertEqual(layout.centerRadius, expectedCenter, accuracy: 0.01,
                       "Center radius should be 15% of available radius")
        XCTAssertEqual(SunburstLayout.centerRadiusFraction, 0.15,
                       "Center radius fraction should be 0.15")
    }

    func testRingRadiiAreConsistent() {
        let tree = makeTestTree()
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
        let layout = SunburstLayout(tree: tree, bounds: bounds, maxRings: 8)

        // Each ring's inner should equal the previous ring's outer
        for ring in 1..<8 {
            XCTAssertEqual(
                layout.innerRadius(forRing: ring),
                layout.outerRadius(forRing: ring - 1),
                accuracy: 0.001,
                "Ring \(ring) inner should equal ring \(ring-1) outer"
            )
        }

        // First ring's inner should be the center radius
        XCTAssertEqual(
            layout.innerRadius(forRing: 0), layout.centerRadius, accuracy: 0.001,
            "Ring 0 inner radius should be the center radius"
        )

        // Last ring's outer should be approximately the available radius
        XCTAssertEqual(
            layout.outerRadius(forRing: 7), layout.availableRadius, accuracy: 0.001,
            "Ring 7 outer radius should be the available radius"
        )
    }

    func testPolarCoordinateConversion() {
        let tree = makeTestTree()
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
        let layout = SunburstLayout(tree: tree, bounds: bounds, maxRings: 8)

        // Point directly above center (12 o'clock) should be angle ~0
        let topPoint = NSPoint(x: 300, y: 200)  // above center in flipped coords
        let (radius1, angle1) = layout.polarCoordinates(for: topPoint)
        XCTAssertEqual(radius1, 100, accuracy: 1.0)
        XCTAssertEqual(angle1, 0, accuracy: 0.1, "Top point should have angle ~0")

        // Point directly to the right (3 o'clock) should be angle ~pi/2
        let rightPoint = NSPoint(x: 400, y: 300)
        let (_, angle2) = layout.polarCoordinates(for: rightPoint)
        XCTAssertEqual(angle2, .pi / 2, accuracy: 0.1, "Right point should have angle ~pi/2")

        // Point directly below center (6 o'clock) should be angle ~pi
        let bottomPoint = NSPoint(x: 300, y: 400)
        let (_, angle3) = layout.polarCoordinates(for: bottomPoint)
        XCTAssertEqual(angle3, .pi, accuracy: 0.1, "Bottom point should have angle ~pi")
    }

    // MARK: - Min Fraction Filtering

    func testMinFractionFiltering() {
        let tree = makeManySpeciesTree(speciesCount: 200)
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)

        // With aggressive filtering, many species should be aggregated to "Other"
        let layout = SunburstLayout(
            tree: tree,
            bounds: bounds,
            maxRings: 8,
            minFractionToShow: 0.05  // 5% threshold
        )

        let segments = layout.computeSegments()
        let otherSegments = segments.filter { $0.isOther }
        let regularSegments = segments.filter { !$0.isOther }

        // Each species is 10/2000 = 0.5%, all below 5% threshold
        // So all species-level segments should be aggregated
        XCTAssertFalse(otherSegments.isEmpty,
                       "There should be 'Other' segments when species are small")

        // With very low threshold, most should pass
        let layoutLow = SunburstLayout(
            tree: tree,
            bounds: bounds,
            maxRings: 8,
            minFractionToShow: 0.0001
        )

        let segmentsLow = layoutLow.computeSegments()
        let regularLow = segmentsLow.filter { !$0.isOther }

        XCTAssertGreaterThan(regularLow.count, regularSegments.count,
                             "Lower threshold should show more individual segments")
    }

    // MARK: - Zoom

    func testZoomChangesCenter() {
        let tree = makeTestTree()
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 600)

        // Default: root is the effective root
        let layoutDefault = SunburstLayout(tree: tree, bounds: bounds, maxRings: 8)
        XCTAssertEqual(layoutDefault.effectiveRoot.taxId, 1,
                       "Default effective root should be the tree root")

        // Zoom to Proteobacteria
        let proteo = tree.node(taxId: 1224)!
        let layoutZoomed = SunburstLayout(
            tree: tree, zoomRoot: proteo, bounds: bounds, maxRings: 8
        )
        XCTAssertEqual(layoutZoomed.effectiveRoot.taxId, 1224,
                       "Zoomed effective root should be Proteobacteria")

        let segmentsZoomed = layoutZoomed.computeSegments()

        // Ring 0 should now contain Proteobacteria's children
        let ring0 = segmentsZoomed.filter { $0.ring == 0 && !$0.isOther }
        let ring0Names = Set(ring0.map { $0.node.name })
        XCTAssertTrue(ring0Names.contains("Gammaproteobacteria"),
                      "Zoomed ring 0 should contain Gammaproteobacteria")
        XCTAssertTrue(ring0Names.contains("Alphaproteobacteria"),
                      "Zoomed ring 0 should contain Alphaproteobacteria")
    }

    // MARK: - Special Cases

    func testTreeWithSingleSpecies() {
        let tree = makeSingleSpeciesTree()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        let layout = SunburstLayout(tree: tree, bounds: bounds, maxRings: 8)

        let segments = layout.computeSegments()
        XCTAssertFalse(segments.isEmpty, "Single species tree should produce segments")

        // Each ring should have exactly 1 segment
        for ring in 0..<3 {
            let ringSegments = segments.filter { $0.ring == ring && !$0.isOther }
            XCTAssertEqual(ringSegments.count, 1,
                           "Ring \(ring) should have exactly 1 segment for single-species tree")
            if let seg = ringSegments.first {
                XCTAssertEqual(seg.angularSpan, 2 * .pi, accuracy: 0.01,
                               "Single segment should span full 360 degrees")
            }
        }
    }

    func testTreeWithManySpecies() {
        let tree = makeManySpeciesTree(speciesCount: 500)
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
        let layout = SunburstLayout(tree: tree, bounds: bounds, maxRings: 8)

        let segments = layout.computeSegments()
        XCTAssertFalse(segments.isEmpty, "Many-species tree should produce segments")

        // Should not have more segments than there are nodes in the tree
        let nodeCount = tree.allNodes().count
        XCTAssertLessThanOrEqual(segments.count, nodeCount + 10,  // +10 for "Other" segments
                                  "Segment count should be bounded")
    }

    func testEmptyTreeHandling() {
        let tree = makeEmptyTree()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        let layout = SunburstLayout(tree: tree, bounds: bounds, maxRings: 8)

        let segments = layout.computeSegments()
        XCTAssertTrue(segments.isEmpty, "Empty tree should produce no segments")
    }

    func testZeroBoundsHandling() {
        let tree = makeTestTree()
        let layout = SunburstLayout(tree: tree, bounds: .zero, maxRings: 8)

        let segments = layout.computeSegments()
        XCTAssertTrue(segments.isEmpty, "Zero bounds should produce no segments")
    }

    func testNegativeBoundsDoesNotCrash() {
        // CGRect normalizes negative width/height to positive values,
        // so this effectively creates a 100x100 rect. The test verifies
        // the layout engine does not crash with unusual CGRect inputs.
        let tree = makeTestTree()
        let layout = SunburstLayout(
            tree: tree,
            bounds: CGRect(x: 0, y: 0, width: -100, height: -100),
            maxRings: 8
        )

        let segments = layout.computeSegments()
        // CGRect.width/height always returns non-negative, so segments are produced
        XCTAssertFalse(segments.isEmpty,
                       "CGRect normalizes negative dimensions; segments should be produced")
    }

    func testMaxRingsLimitsDepth() {
        let tree = makeTestTree()
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 600)

        // With maxRings=2, we should only see rings 0 and 1
        let layout = SunburstLayout(
            tree: tree, bounds: bounds, maxRings: 2, minFractionToShow: 0.001
        )

        let segments = layout.computeSegments()
        let maxRing = segments.map(\.ring).max() ?? -1
        XCTAssertLessThan(maxRing, 2,
                          "No segment should be beyond ring index 1 when maxRings=2")
    }

    // MARK: - Segment Path

    func testSegmentBezierPathIsValid() {
        let segment = SunburstSegment(
            node: makeTestTree().root,
            ring: 0,
            innerRadius: 50,
            outerRadius: 100,
            startAngle: 0,
            endAngle: .pi / 2,
            color: .blue,
            isOther: false
        )

        let path = segment.bezierPath(center: NSPoint(x: 200, y: 200))
        XCTAssertFalse(path.isEmpty, "Bezier path should not be empty")
        XCTAssertGreaterThan(path.elementCount, 0, "Path should have elements")
    }

    func testSegmentContainsPoint() {
        let segment = SunburstSegment(
            node: makeTestTree().root,
            ring: 0,
            innerRadius: 50,
            outerRadius: 100,
            startAngle: 0,
            endAngle: .pi / 2,
            color: .blue,
            isOther: false
        )

        // Point at midRadius, midAngle should be inside
        XCTAssertTrue(
            segment.containsPoint(radius: 75, angle: .pi / 4),
            "Mid-point should be inside the segment"
        )

        // Point at correct angle but wrong radius should be outside
        XCTAssertFalse(
            segment.containsPoint(radius: 30, angle: .pi / 4),
            "Point inside inner radius should be outside"
        )

        // Point at correct radius but wrong angle should be outside
        XCTAssertFalse(
            segment.containsPoint(radius: 75, angle: .pi),
            "Point at wrong angle should be outside"
        )
    }
}

// MARK: - PhylumPalette Tests

@MainActor
final class TaxonomyPhylumPaletteTests: XCTestCase {

    func testPhylumColorAssignment() {
        // Each of the 20 slots should return a non-nil color
        for i in 0..<PhylumPalette.slotCount {
            let color = PhylumPalette.phylumColor(index: i)
            XCTAssertNotNil(color, "Phylum slot \(i) should return a color")
        }
    }

    func testPhylumColorOverflowUsesOther() {
        let overflowColor = PhylumPalette.phylumColor(index: 25)
        let otherColor = PhylumPalette.phylumColor(index: 19)
        // Both should be the "Other" slot
        XCTAssertEqual(overflowColor, otherColor,
                       "Overflow index should return the 'Other' color (slot 19)")
    }

    func testNegativeIndexUsesOther() {
        let color = PhylumPalette.phylumColor(index: -1)
        let otherColor = PhylumPalette.phylumColor(index: 19)
        XCTAssertEqual(color, otherColor,
                       "Negative index should return the 'Other' color")
    }

    func testColorConsistency() {
        // Same node should always get the same color
        let tree = makeTestTree()
        let proteo = tree.node(taxId: 1224)!

        let color1 = PhylumPalette.color(for: proteo)
        let color2 = PhylumPalette.color(for: proteo)

        // NSColor objects from the same factory should be equal
        XCTAssertEqual(color1, color2,
                       "Same node should always get the same color")
    }

    func testPhylumInfoForPhylumNode() {
        let tree = makeTestTree()
        let proteo = tree.node(taxId: 1224)!

        let (_, depth) = PhylumPalette.phylumInfo(for: proteo)
        XCTAssertEqual(depth, 0, "Phylum node should have depth 0 below phylum")
    }

    func testPhylumInfoForSpeciesNode() {
        let tree = makeTestTree()
        let ecoli = tree.node(taxId: 562)!

        let (_, depth) = PhylumPalette.phylumInfo(for: ecoli)
        XCTAssertGreaterThan(depth, 0,
                             "Species should have depth > 0 below phylum")
    }

    func testSamePhylumChildrenShareBaseHue() {
        let tree = makeTestTree()
        let proteo = tree.node(taxId: 1224)!
        let gamma = tree.node(taxId: 1236)!

        let (proteoIdx, _) = PhylumPalette.phylumInfo(for: proteo)
        let (gammaIdx, _) = PhylumPalette.phylumInfo(for: gamma)

        XCTAssertEqual(proteoIdx, gammaIdx,
                       "Nodes under same phylum should have same phylum index")
    }

    func testDepthTintingReducesSaturation() {
        let baseColor = NSColor(hue: 0.5, saturation: 0.8, brightness: 0.7, alpha: 1.0)

        let tinted = PhylumPalette.tintedColor(base: baseColor, depthBelowPhylum: 3)

        // Resolve for current appearance
        var tH: CGFloat = 0, tS: CGFloat = 0, tB: CGFloat = 0, tA: CGFloat = 0
        let resolved = tinted.usingColorSpace(.sRGB) ?? tinted
        resolved.getHue(&tH, saturation: &tS, brightness: &tB, alpha: &tA)

        // Expected: saturation = 0.8 * (1.0 - 0.12 * 3) = 0.8 * 0.64 = 0.512
        XCTAssertLessThan(tS, 0.8, "Tinted saturation should be less than base")
    }

    func testDepthTintingIncreasesBrightness() {
        let baseColor = NSColor(hue: 0.5, saturation: 0.8, brightness: 0.6, alpha: 1.0)

        let tinted = PhylumPalette.tintedColor(base: baseColor, depthBelowPhylum: 3)

        var tH: CGFloat = 0, tS: CGFloat = 0, tB: CGFloat = 0, tA: CGFloat = 0
        let resolved = tinted.usingColorSpace(.sRGB) ?? tinted
        resolved.getHue(&tH, saturation: &tS, brightness: &tB, alpha: &tA)

        // Expected: brightness = min(0.95, 0.6 + 0.06 * 3) = 0.78
        XCTAssertGreaterThan(tB, 0.6, "Tinted brightness should be greater than base")
        XCTAssertLessThanOrEqual(tB, 0.95, "Tinted brightness should not exceed 0.95")
    }

    func testDepthTintingZeroDepthReturnsBase() {
        let baseColor = NSColor(hue: 0.5, saturation: 0.8, brightness: 0.7, alpha: 1.0)
        let tinted = PhylumPalette.tintedColor(base: baseColor, depthBelowPhylum: 0)
        XCTAssertEqual(tinted, baseColor,
                       "Zero depth should return base color unchanged")
    }

    func testSaturationClampedAtMinimum() {
        let baseColor = NSColor(hue: 0.5, saturation: 0.3, brightness: 0.7, alpha: 1.0)

        // At depth 10: saturation = 0.3 * (1.0 - 0.12 * 10) = 0.3 * (-0.2) < 0
        // Should clamp to 0.15
        let tinted = PhylumPalette.tintedColor(base: baseColor, depthBelowPhylum: 10)

        var tH: CGFloat = 0, tS: CGFloat = 0, tB: CGFloat = 0, tA: CGFloat = 0
        let resolved = tinted.usingColorSpace(.sRGB) ?? tinted
        resolved.getHue(&tH, saturation: &tS, brightness: &tB, alpha: &tA)

        XCTAssertGreaterThanOrEqual(tS, 0.14,  // slight tolerance
                                     "Saturation should not drop below 0.15")
    }

    func testDarkModeColorAdjustment() {
        // We can test that the color factory creates valid colors for both appearances
        let lightAppearance = NSAppearance(named: .aqua)!
        let darkAppearance = NSAppearance(named: .darkAqua)!

        let color = PhylumPalette.phylumColor(index: 0)

        // Resolve for light mode
        var lR: CGFloat = 0, lG: CGFloat = 0, lB: CGFloat = 0, lA: CGFloat = 0
        lightAppearance.performAsCurrentDrawingAppearance {
            let lightResolved = color.usingColorSpace(.sRGB)
            lightResolved?.getRed(&lR, green: &lG, blue: &lB, alpha: &lA)
        }

        // Resolve for dark mode
        var dR: CGFloat = 0, dG: CGFloat = 0, dB: CGFloat = 0, dA: CGFloat = 0
        darkAppearance.performAsCurrentDrawingAppearance {
            let darkResolved = color.usingColorSpace(.sRGB)
            darkResolved?.getRed(&dR, green: &dG, blue: &dB, alpha: &dA)
        }

        // Dark mode should generally be brighter (higher RGB values)
        let lightLum = PhylumPalette.relativeLuminance(r: lR, g: lG, b: lB)
        let darkLum = PhylumPalette.relativeLuminance(r: dR, g: dG, b: dB)
        XCTAssertGreaterThan(darkLum, lightLum,
                             "Dark mode variant should have higher luminance than light mode")
    }

    func testContrastingTextColorForDark() {
        let darkBG = NSColor(hue: 0.5, saturation: 0.8, brightness: 0.2, alpha: 1.0)
        let textColor = PhylumPalette.contrastingTextColor(for: darkBG)
        XCTAssertEqual(textColor, .white,
                       "Dark background should produce white text")
    }

    func testContrastingTextColorForLight() {
        let lightBG = NSColor(hue: 0.5, saturation: 0.1, brightness: 0.95, alpha: 1.0)
        let textColor = PhylumPalette.contrastingTextColor(for: lightBG)
        XCTAssertEqual(textColor, .black,
                       "Light background should produce black text")
    }

    func testStablePhylumIndexDeterministic() {
        // Same taxId should always produce the same index
        let idx1 = PhylumPalette.stablePhylumIndex(taxId: 1224)
        let idx2 = PhylumPalette.stablePhylumIndex(taxId: 1224)
        XCTAssertEqual(idx1, idx2, "Same taxId should produce same index")

        // Index should be in valid range
        XCTAssertGreaterThanOrEqual(idx1, 0)
        XCTAssertLessThan(idx1, PhylumPalette.slotCount - 1)
    }

    func testDifferentPhylaGetDifferentIndices() {
        // This isn't guaranteed for all pairs (hash collisions), but for these
        // common phyla the hash should spread them well enough.
        var indices = Set<Int>()
        let testTaxIds = [1224, 1239, 201174, 976, 1760, 32066]
        for taxId in testTaxIds {
            indices.insert(PhylumPalette.stablePhylumIndex(taxId: taxId))
        }

        // At least half should be unique (allowing for some collisions)
        XCTAssertGreaterThanOrEqual(indices.count, testTaxIds.count / 2,
                                     "Different phyla should generally get different color slots")
    }
}

// MARK: - TaxonomyTableView Tests

@MainActor
final class TaxonomyTableViewTests: XCTestCase {

    func testOutlineViewDataSourceCount() {
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let tree = makeTestTree()
        table.tree = tree

        // Root's children count: Bacteria and Archaea
        let rootChildCount = table.sortedChildren(of: tree.root).count
        XCTAssertEqual(rootChildCount, 2,
                       "Root should have 2 children (Bacteria and Archaea)")
    }

    func testOutlineViewHierarchy() {
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let tree = makeTestTree()
        table.tree = tree

        // Bacteria's children
        let bacteria = tree.node(taxId: 2)!
        let bacteriaChildren = table.sortedChildren(of: bacteria)
        XCTAssertEqual(bacteriaChildren.count, 3,
                       "Bacteria should have 3 phylum children")

        // Check names
        let names = Set(bacteriaChildren.map(\.name))
        XCTAssertTrue(names.contains("Proteobacteria"))
        XCTAssertTrue(names.contains("Firmicutes"))
        XCTAssertTrue(names.contains("Actinobacteria"))
    }

    func testFilterPreservesContext() {
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let tree = makeTestTree()
        table.tree = tree

        // We can't easily test the full filter pipeline without driving the
        // NSOutlineView, but we can verify the sorting + filtering logic.

        // Simulate a filter for "Escherichia"
        // This node is deeply nested: root > Bacteria > Proteobacteria >
        //   Gammaproteobacteria > Enterobacterales > Enterobacteriaceae > Escherichia

        // Verify the node exists and has the right properties
        let escherichia = tree.node(taxId: 561)!
        XCTAssertEqual(escherichia.name, "Escherichia")

        let path = escherichia.pathFromRoot()
        XCTAssertGreaterThan(path.count, 3,
                             "Escherichia path should include multiple ancestors")
        XCTAssertEqual(path.first?.taxId, 1, "Path should start at root")
        XCTAssertEqual(path.last?.taxId, 561, "Path should end at Escherichia")
    }

    func testSortingByCladeDescending() {
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let tree = makeTestTree()
        table.tree = tree

        // Default sort is by clade descending
        let bacteria = tree.node(taxId: 2)!
        let children = table.sortedChildren(of: bacteria)

        // Proteobacteria (5000) > Firmicutes (2000) > Actinobacteria (1000)
        XCTAssertEqual(children[0].name, "Proteobacteria",
                       "First child should be Proteobacteria (highest clade)")
        XCTAssertEqual(children[1].name, "Firmicutes",
                       "Second child should be Firmicutes")
        XCTAssertEqual(children[2].name, "Actinobacteria",
                       "Third child should be Actinobacteria (lowest clade)")
    }

    func testNilTreeHandling() {
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        table.tree = nil

        // Should not crash
        let count = table.outlineView(
            NSOutlineView(),
            numberOfChildrenOfItem: nil
        )
        XCTAssertEqual(count, 0, "Nil tree should return 0 children")
    }
}

// MARK: - TaxonomySunburstView Tests

@MainActor
final class TaxonomySunburstViewTests: XCTestCase {

    func testSunburstViewInitialization() {
        let view = TaxonomySunburstView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertNil(view.tree, "Initial tree should be nil")
        XCTAssertNil(view.centerNode, "Initial center node should be nil")
        XCTAssertNil(view.selectedNode, "Initial selected node should be nil")
        XCTAssertNil(view.hoveredNode, "Initial hovered node should be nil")
        XCTAssertEqual(view.maxRings, 8, "Default max rings should be 8")
        XCTAssertEqual(view.minFractionToShow, 0.001, accuracy: 0.0001)
    }

    func testSunburstViewWithNilTree() {
        let view = TaxonomySunburstView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.tree = nil

        // Should not crash when drawing
        let image = NSImage(size: view.bounds.size, flipped: true) { rect in
            view.draw(rect)
            return true
        }
        XCTAssertNotNil(image, "Drawing with nil tree should not crash")
    }

    func testSunburstViewWithEmptyTree() {
        let view = TaxonomySunburstView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.tree = makeEmptyTree()

        let image = NSImage(size: view.bounds.size, flipped: true) { rect in
            view.draw(rect)
            return true
        }
        XCTAssertNotNil(image, "Drawing with empty tree should not crash")
    }

    func testSunburstViewWithValidTree() {
        let view = TaxonomySunburstView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        view.tree = makeTestTree()

        let image = NSImage(size: view.bounds.size, flipped: true) { rect in
            view.draw(rect)
            return true
        }
        XCTAssertNotNil(image, "Drawing with valid tree should not crash")
    }

    func testSunburstViewIsFlipped() {
        let view = TaxonomySunburstView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertTrue(view.isFlipped, "Sunburst view should use flipped coordinates")
    }

    func testSunburstViewAcceptsFirstResponder() {
        let view = TaxonomySunburstView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertTrue(view.acceptsFirstResponder,
                      "Sunburst view should accept first responder for keyboard events")
    }
}

// MARK: - TaxonomyTooltipView Tests

@MainActor
final class TaxonomyTooltipViewTests: XCTestCase {

    func testTooltipUpdate() {
        let tooltip = TaxonomyTooltipView(frame: NSRect(x: 0, y: 0, width: 220, height: 120))
        let tree = makeTestTree()
        let ecoli = tree.node(taxId: 562)!

        tooltip.update(with: ecoli, totalReads: tree.totalReads)

        let size = tooltip.preferredSize
        XCTAssertGreaterThan(size.width, 0, "Tooltip should have positive width")
        XCTAssertGreaterThan(size.height, 0, "Tooltip should have positive height")
    }

    func testTooltipMinimumWidth() {
        let tooltip = TaxonomyTooltipView(frame: NSRect(x: 0, y: 0, width: 220, height: 120))
        let tree = makeTestTree()
        let root = tree.root

        tooltip.update(with: root, totalReads: tree.totalReads)

        let size = tooltip.preferredSize
        XCTAssertGreaterThanOrEqual(size.width, 160,
                                     "Tooltip should have minimum width of 160")
    }

    func testTooltipDrawsWithoutCrash() {
        let tooltip = TaxonomyTooltipView(frame: NSRect(x: 0, y: 0, width: 220, height: 120))
        let tree = makeTestTree()
        let ecoli = tree.node(taxId: 562)!

        tooltip.update(with: ecoli, totalReads: tree.totalReads)

        let image = NSImage(size: tooltip.bounds.size, flipped: true) { rect in
            tooltip.draw(rect)
            return true
        }
        XCTAssertNotNil(image, "Drawing tooltip should not crash")
    }
}

// MARK: - Angle Normalization Tests

@MainActor
final class AngleNormalizationTests: XCTestCase {

    func testNormalizePositiveAngle() {
        let angle = normalizeAngle(3 * .pi / 2)
        XCTAssertEqual(angle, 3 * .pi / 2, accuracy: 0.001)
    }

    func testNormalizeNegativeAngle() {
        let angle = normalizeAngle(-.pi / 2)
        XCTAssertEqual(angle, 3 * .pi / 2, accuracy: 0.001)
    }

    func testNormalizeLargeAngle() {
        let angle = normalizeAngle(5 * .pi)
        XCTAssertEqual(angle, .pi, accuracy: 0.001)
    }

    func testNormalizeZero() {
        let angle = normalizeAngle(0)
        XCTAssertEqual(angle, 0, accuracy: 0.001)
    }

    func testNormalizeTwoPi() {
        let angle = normalizeAngle(2 * .pi)
        // Should wrap to 0
        XCTAssertEqual(angle, 0, accuracy: 0.001)
    }
}
