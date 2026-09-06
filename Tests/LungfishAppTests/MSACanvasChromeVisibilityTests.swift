// MSACanvasChromeVisibilityTests.swift - The alignment chrome must actually paint
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
import LungfishIO

/// Preview 2026.9.12 shipped with the sequence-name gutter, the corner title
/// and the column header blank on screen even though layout and accessibility
/// were correct. The pinned comparison row and its label open their `draw`
/// with `dirtyRect.fill()`, and since macOS 14 a view's dirty rect is no
/// longer clipped to its bounds, so those two fills erased every sibling
/// drawn before them. These tests render the viewer through the real display
/// pipeline and assert that each piece of chrome still carries ink.
@MainActor
final class MSACanvasChromeVisibilityTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var savedGutterWidth: Any?

    override func setUpWithError() throws {
        savedGutterWidth = UserDefaults.standard.object(forKey: MultipleSequenceAlignmentViewController.gutterWidthDefaultsKey)
        UserDefaults.standard.removeObject(forKey: MultipleSequenceAlignmentViewController.gutterWidthDefaultsKey)
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let savedGutterWidth {
            UserDefaults.standard.set(savedGutterWidth, forKey: MultipleSequenceAlignmentViewController.gutterWidthDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: MultipleSequenceAlignmentViewController.gutterWidthDefaultsKey)
        }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func controller(rowCount: Int = 20) async throws -> MultipleSequenceAlignmentViewController {
        let source = temporaryDirectory.appendingPathComponent("input.fa")
        let sequences = ["ACGT-AACGTTACGGTACGT", "ACCTTAACGTTACGGTACGT", "AC-TTAACGTTACGGTACGT"]
        let fasta = (0..<rowCount).map { ">sequence-\($0)-accession\n\(sequences[$0 % sequences.count])\n" }.joined()
        try fasta.write(to: source, atomically: true, encoding: .utf8)
        let bundle = temporaryDirectory.appendingPathComponent("test.lungfishmsa")
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: source, to: bundle)
        let controller = MultipleSequenceAlignmentViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        try await controller.displayBundle(at: bundle)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func descendant(_ root: NSView, _ identifier: String) throws -> NSView {
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let found = try? descendant(child, identifier) { return found }
        }
        throw NSError(domain: "Missing view \(identifier)", code: 1)
    }

    private func describeHierarchy(_ view: NSView, depth: Int = 0, into lines: inout [String]) {
        let identifier = view.accessibilityIdentifier()
        let id = identifier.isEmpty ? "" : " id=\(identifier)"
        lines.append(String(repeating: "  ", count: depth) + "\(type(of: view)) frame=\(view.frame) hidden=\(view.isHidden)\(id)")
        for child in view.subviews {
            describeHierarchy(child, depth: depth + 1, into: &lines)
        }
    }

    /// The share of pixels inside `region` (root coordinates) whose luminance
    /// differs from the region's top-left background by more than 0.3.
    private func inkRatio(in region: NSRect, of root: NSView, rep: NSBitmapImageRep) -> Double {
        let scaleX = CGFloat(rep.pixelsWide) / root.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / root.bounds.height
        func pixelRow(forViewY y: CGFloat) -> Int {
            root.isFlipped ? Int(y * scaleY) : Int((root.bounds.height - y) * scaleY)
        }
        let minX = max(0, Int(region.minX * scaleX))
        let maxX = min(rep.pixelsWide, Int(region.maxX * scaleX))
        let rows = [pixelRow(forViewY: region.minY), pixelRow(forViewY: region.maxY)]
        let minRow = max(0, rows.min()!)
        let maxRow = min(rep.pixelsHigh, rows.max()!)
        guard minX < maxX, minRow < maxRow else { return 0 }
        func luminance(_ x: Int, _ y: Int) -> Double {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
            return 0.2126 * Double(color.redComponent) + 0.7152 * Double(color.greenComponent) + 0.0722 * Double(color.blueComponent)
        }
        let background = luminance(minX + 2, minRow + 2)
        var contrasting = 0
        var total = 0
        for y in minRow..<maxRow {
            for x in minX..<maxX {
                total += 1
                if abs(luminance(x, y) - background) > 0.3 { contrasting += 1 }
            }
        }
        return total == 0 ? 0 : Double(contrasting) / Double(total)
    }

    private func render(_ root: NSView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        return rep
    }

    func testGutterCornerHeaderAndComparisonLabelPaintThroughTheDisplayPipeline() async throws {
        let controller = try await controller()
        let root = controller.view
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = root
        defer { window.contentView = nil }
        window.layoutIfNeeded()
        root.layoutSubtreeIfNeeded()

        let gutter = try descendant(root, "multiple-sequence-alignment-row-gutter")
        let header = try descendant(root, "multiple-sequence-alignment-column-header")
        let label = try descendant(root, "msaComparisonLabel")
        let pinned = try descendant(root, "msaComparisonHeader")
        let matrix = try descendant(root, "multiple-sequence-alignment-matrix-view")
        let canvas = try XCTUnwrap(gutter.superview)
        let corner = try XCTUnwrap(canvas.subviews.first { $0.frame.minX == 0 && $0.frame.maxY == canvas.bounds.maxY })
        let scroll = try XCTUnwrap(matrix.enclosingScrollView)

        var lines: [String] = []
        describeHierarchy(root, into: &lines)
        let hierarchy = lines.joined(separator: "\n")

        let rep = try render(root)
        var report: [String] = []
        var ink: [String: Double] = [:]
        for (name, view) in [("gutter", gutter), ("header", header), ("corner", corner), ("label", label), ("pinned", pinned), ("scroll", scroll)] {
            let value = inkRatio(in: view.convert(view.bounds, to: root), of: root, rep: rep)
            ink[name] = value
            report.append("\(name): \(value)")
        }
        let evidence = report.joined(separator: "\n") + "\n" + hierarchy

        XCTAssertGreaterThan(ink["gutter"] ?? 0, 0.02, "sequence names are not painted in the gutter\n\(evidence)")
        XCTAssertGreaterThan(ink["header"] ?? 0, 0.001, "column numbering is not painted in the header\n\(evidence)")
        XCTAssertGreaterThan(ink["corner"] ?? 0, 0.01, "the corner title is not painted\n\(evidence)")
        XCTAssertGreaterThan(ink["label"] ?? 0, 0.01, "the comparison label is not painted\n\(evidence)")
        XCTAssertGreaterThan(ink["pinned"] ?? 0, 0.01, "the pinned comparison row is not painted\n\(evidence)")
        XCTAssertGreaterThan(ink["scroll"] ?? 0, 0.1, "the alignment matrix is not painted\n\(evidence)")
    }

    func testEveryCanvasChromeViewClipsItsDrawingToItsBounds() async throws {
        let controller = try await controller()
        let root = controller.view
        let gutter = try descendant(root, "multiple-sequence-alignment-row-gutter")
        let canvas = try XCTUnwrap(gutter.superview)
        let matrix = try descendant(root, "multiple-sequence-alignment-matrix-view")
        for view in canvas.subviews + [matrix] where !(view is NSScrollView) {
            XCTAssertTrue(view.clipsToBounds, "\(type(of: view)) must clip drawing to its bounds")
        }
    }

    func testGutterStillPaintsAfterScrollingAndReconfiguring() async throws {
        let controller = try await controller(rowCount: 90)
        let root = controller.view
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = root
        defer { window.contentView = nil }
        window.layoutIfNeeded()
        root.layoutSubtreeIfNeeded()

        let gutter = try descendant(root, "multiple-sequence-alignment-row-gutter")
        let matrix = try descendant(root, "multiple-sequence-alignment-matrix-view")
        let scroll = try XCTUnwrap(matrix.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 125))
        scroll.reflectScrolledClipView(scroll.contentView)
        controller.testingSelectReferenceRow(named: "sequence-3-accession")
        controller.applyResidueIdentityDisplayMode(.dotsToReference)
        root.layoutSubtreeIfNeeded()

        let rep = try render(root)
        let gutterInk = inkRatio(in: gutter.convert(gutter.bounds, to: root), of: root, rep: rep)
        XCTAssertGreaterThan(gutterInk, 0.02, "sequence names vanished after scrolling and changing the comparison target")
    }
}
