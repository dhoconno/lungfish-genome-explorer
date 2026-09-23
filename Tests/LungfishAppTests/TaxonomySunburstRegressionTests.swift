import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class TaxonomySunburstRegressionTests: XCTestCase {
    private func tree(singleChild: Bool = false) -> TaxonTree {
        func node(_ id: Int, _ name: String, _ clade: Int, _ direct: Int) -> TaxonNode {
            TaxonNode(
                taxId: id,
                name: name,
                rank: id == 1 ? .root : .phylum,
                depth: id == 1 ? 0 : 1,
                readsDirect: direct,
                readsClade: clade,
                fractionClade: Double(clade) / 1000,
                fractionDirect: Double(direct) / 1000,
                parentTaxId: id == 1 ? nil : 1
            )
        }

        let root = node(1, "Root", 100, singleChild ? 0 : 10)
        root.children = singleChild
            ? [node(2, "Only taxon", 100, 100)]
            : [node(2, "Alpha", 70, 70), node(3, "Beta", 20, 20)]
        for child in root.children {
            child.parent = root
        }
        return TaxonTree(root: root, unclassifiedNode: nil, totalReads: 1000)
    }

    private func unevenTree() -> TaxonTree {
        func node(
            _ id: Int,
            _ name: String,
            _ rank: TaxonomicRank,
            _ depth: Int,
            _ clade: Int,
            _ direct: Int,
            _ parentTaxId: Int?
        ) -> TaxonNode {
            TaxonNode(
                taxId: id,
                name: name,
                rank: rank,
                depth: depth,
                readsDirect: direct,
                readsClade: clade,
                fractionClade: Double(clade) / 1000,
                fractionDirect: Double(direct) / 1000,
                parentTaxId: parentTaxId
            )
        }

        let root = node(1, "Root", .root, 0, 100, 10, nil)
        let alpha = node(2, "Alpha", .phylum, 1, 70, 0, 1)
        let beta = node(3, "Beta", .phylum, 1, 20, 20, 1)
        let gamma = node(4, "Gamma", .class, 2, 50, 10, 2)
        let delta = node(5, "Delta", .class, 2, 20, 20, 2)
        let epsilon = node(6, "Epsilon", .order, 3, 40, 40, 4)

        root.addChild(alpha)
        root.addChild(beta)
        alpha.addChild(gamma)
        alpha.addChild(delta)
        gamma.addChild(epsilon)
        return TaxonTree(root: root, unclassifiedNode: nil, totalReads: 1000)
    }

    private func point(_ layout: SunburstLayout, radius: CGFloat, angle: CGFloat) -> NSPoint {
        NSPoint(
            x: layout.center.x + radius * sin(angle),
            y: layout.center.y - radius * cos(angle)
        )
    }

    private func segment(_ start: CGFloat, _ end: CGFloat) -> SunburstSegment {
        SunburstSegment(
            node: tree().root,
            ring: 0,
            innerRadius: 40,
            outerRadius: 80,
            startAngle: start,
            endAngle: end,
            color: .red,
            isOther: false
        )
    }

    private func event(
        _ type: NSEvent.EventType,
        in view: NSView,
        at point: NSPoint,
        clicks: Int = 1
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: clicks,
            pressure: 1
        ))
    }

    func testQuarterPathsAgreeWithPolarCoordinates() {
        let layout = SunburstLayout(
            tree: tree(),
            bounds: CGRect(x: 0, y: 0, width: 400, height: 400)
        )
        for quadrant in 0..<4 {
            let start = CGFloat(quadrant) * .pi / 2
            let sector = segment(start, start + .pi / 2)
            let inside = point(layout, radius: 60, angle: sector.midAngle)
            let reflected = NSPoint(x: inside.x, y: 2 * layout.center.y - inside.y)
            XCTAssertTrue(sector.bezierPath(center: layout.center).contains(inside))
            XCTAssertFalse(sector.bezierPath(center: layout.center).contains(reflected))
            XCTAssertTrue(sector.containsPoint(radius: 60, angle: sector.midAngle))
        }
    }

    func testFullCircleHitsEveryCardinalPoint() {
        let layout = SunburstLayout(
            tree: tree(singleChild: true),
            bounds: CGRect(x: 0, y: 0, width: 400, height: 400)
        )
        let segments = layout.computeSegments()
        let sector = segments[0]
        for angle in [CGFloat(0), .pi / 2, .pi, 3 * .pi / 2] {
            let location = point(layout, radius: sector.midRadius, angle: angle)
            XCTAssertTrue(sector.bezierPath(center: layout.center).contains(location))
            XCTAssertEqual(layout.hitTest(point: location, segments: segments)?.node.taxId, 2)
        }
        XCTAssertFalse(sector.containsPoint(radius: sector.innerRadius - 1, angle: .pi))
        XCTAssertFalse(sector.containsPoint(radius: sector.outerRadius + 1, angle: .pi))
    }

    func testSeamAndEmptySpan() {
        let wrapped = segment(7 * .pi / 4, 9 * .pi / 4)
        XCTAssertTrue(wrapped.containsPoint(radius: 60, angle: 0))
        XCTAssertTrue(wrapped.containsPoint(radius: 60, angle: 2 * .pi))
        XCTAssertFalse(wrapped.containsPoint(radius: 60, angle: .pi))
        XCTAssertFalse(segment(0, 0).containsPoint(radius: 60, angle: 0))
        XCTAssertTrue(segment(7 * .pi / 4, .pi / 4).containsPoint(radius: 60, angle: 0))
    }

    func testDirectReadGapAndOtherPreserveMass() {
        let taxonomy = tree()
        for threshold in [0.001, 0.25] {
            let layout = SunburstLayout(
                tree: taxonomy,
                bounds: CGRect(x: 0, y: 0, width: 400, height: 400),
                minFractionToShow: threshold
            )
            let segments = layout.computeSegments().filter { $0.ring == 0 }
            XCTAssertEqual(segments.count, 2)
            XCTAssertEqual(segments[0].angularSpanDegrees, 252, accuracy: 1e-8)
            XCTAssertEqual(segments[1].angularSpanDegrees, 72, accuracy: 1e-8)
            XCTAssertEqual(segments[1].isOther, threshold == 0.25)
            let gap = point(layout, radius: segments[0].midRadius, angle: 1.9 * .pi)
            XCTAssertNil(layout.hitTest(point: gap, segments: segments))
            XCTAssertTrue(segments.allSatisfy {
                !$0.bezierPath(center: layout.center).contains(gap)
            })
        }
        XCTAssertEqual(taxonomy.root.readsClade, 100)
        XCTAssertEqual(taxonomy.root.readsDirect, 10)
        XCTAssertEqual(taxonomy.totalReads, 1000)
    }

    func testMouseCallbacksFollowRenderedSectorsAndResize() throws {
        let taxonomy = tree()
        let view = TaxonomySunburstView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.tree = taxonomy
        var selected: TaxonNode?
        var rightClicked: TaxonNode?
        var emptyRightClicks = 0
        view.onNodeSelected = { selected = $0 }
        view.onNodeRightClicked = { node, _ in rightClicked = node }
        view.onEmptySpaceRightClicked = { _ in emptyRightClicks += 1 }

        for size in [NSSize(width: 400, height: 400), NSSize(width: 700, height: 500)] {
            view.setFrameSize(size)
            view.layoutSubtreeIfNeeded()
            let layout = SunburstLayout(tree: taxonomy, bounds: view.bounds)
            let sectors = layout.computeSegments()
            for sector in sectors where !sector.isOther {
                let location = point(layout, radius: sector.midRadius, angle: sector.midAngle)
                XCTAssertTrue(sector.bezierPath(center: layout.center).contains(location))
                view.mouseMoved(with: try event(.mouseMoved, in: view, at: location))
                XCTAssertTrue(view.hoveredNode === sector.node)
                view.mouseDown(with: try event(.leftMouseDown, in: view, at: location))
                XCTAssertTrue(view.selectedNode === sector.node)
                XCTAssertTrue(selected === sector.node)
                view.rightMouseDown(with: try event(.rightMouseDown, in: view, at: location))
                XCTAssertTrue(rightClicked === sector.node)
            }

            let gap = point(layout, radius: sectors[0].midRadius, angle: 1.9 * .pi)
            view.mouseMoved(with: try event(.mouseMoved, in: view, at: gap))
            XCTAssertNil(view.hoveredNode)
            view.rightMouseDown(with: try event(.rightMouseDown, in: view, at: gap))
        }
        XCTAssertEqual(emptyRightClicks, 2)

        let layout = SunburstLayout(tree: taxonomy, bounds: view.bounds)
        let sector = layout.computeSegments()[0]
        let location = point(layout, radius: sector.midRadius, angle: sector.midAngle)
        view.mouseMoved(with: try event(.mouseMoved, in: view, at: location))
        XCTAssertNotNil(view.hoveredNode)
        view.mouseDown(with: try event(.leftMouseDown, in: view, at: location, clicks: 2))
        XCTAssertTrue(view.centerNode === sector.node)
        XCTAssertNil(view.hoveredNode)

        view.zoomToRoot()
        view.hoveredNode = taxonomy.root.children[0]
        view.tree = tree(singleChild: true)
        XCTAssertNil(view.hoveredNode)
    }

    func testFullRingViewEventsHitEveryCardinalPoint() throws {
        let taxonomy = tree(singleChild: true)
        let view = TaxonomySunburstView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.tree = taxonomy
        view.layoutSubtreeIfNeeded()
        let layout = SunburstLayout(tree: taxonomy, bounds: view.bounds)
        let sector = layout.computeSegments()[0]

        for angle in [CGFloat(0), .pi / 2, .pi, 3 * .pi / 2] {
            let location = point(layout, radius: sector.midRadius, angle: angle)
            view.mouseMoved(with: try event(.mouseMoved, in: view, at: location))
            XCTAssertTrue(view.hoveredNode === taxonomy.root.children[0])
            view.mouseDown(with: try event(.leftMouseDown, in: view, at: location))
            XCTAssertTrue(view.selectedNode === taxonomy.root.children[0])
        }

        view.mouseExited(with: try event(.mouseMoved, in: view, at: .zero))
        XCTAssertNil(view.hoveredNode)
    }

    func testResizeInvalidationClearsHoverAndRebuildsHitTargets() throws {
        let taxonomy = tree()
        let view = TaxonomySunburstView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.tree = taxonomy
        view.layoutSubtreeIfNeeded()
        view.hoveredNode = taxonomy.root.children[0]

        view.setFrameSize(NSSize(width: 700, height: 500))
        view.layout()
        XCTAssertNil(view.hoveredNode)

        let layout = SunburstLayout(tree: taxonomy, bounds: view.bounds)
        let sector = layout.computeSegments()[0]
        let location = point(layout, radius: sector.midRadius, angle: sector.midAngle)
        view.mouseMoved(with: try event(.mouseMoved, in: view, at: location))
        XCTAssertTrue(view.hoveredNode === sector.node)
    }

    func testRenderedDiagnostic() throws {
        let view = TaxonomySunburstView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        view.tree = unevenTree()
        view.maxRings = 3
        view.appearance = NSAppearance(named: .aqua)

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 700,
            pixelsHigh: 700,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = NSSize(width: 700, height: 700)
        view.cacheDisplay(in: view.bounds, to: rep)

        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/krona-qa", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("sunburst.png"))
        XCTAssertFalse(png.isEmpty)
    }

    func testTooltipUsesDistinctTotalAndClassifiedDenominators() {
        let tooltip = TaxonomyTooltipView(frame: .zero)
        let taxonomy = tree()
        tooltip.update(
            with: taxonomy.root.children[0],
            totalReads: taxonomy.totalReads,
            classifiedReads: taxonomy.classifiedReads
        )
        XCTAssertEqual(tooltip.percentOfTotal, 7, accuracy: 1e-8)
        XCTAssertEqual(tooltip.percentOfClassified, 70, accuracy: 1e-8)

        tooltip.update(with: taxonomy.root, totalReads: 0, classifiedReads: 0)
        XCTAssertEqual(tooltip.percentOfTotal, 0)
        XCTAssertEqual(tooltip.percentOfClassified, 0)
    }
}
