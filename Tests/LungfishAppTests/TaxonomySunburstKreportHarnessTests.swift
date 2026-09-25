// TaxonomySunburstKreportHarnessTests.swift - Diagnostic harness for a real kreport
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Set LUNGFISH_KRONA_KREPORT to a kreport path and LUNGFISH_KRONA_OUT to an
// output directory. The test dumps every wedge and renders the view to PNG.

import AppKit
import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishKit
import LungfishWorkflow

@MainActor
final class TaxonomySunburstKreportHarnessTests: XCTestCase {

    func testDumpAndRenderRealKreport() throws {
        let env = ProcessInfo.processInfo.environment
        guard let kreportPath = env["LUNGFISH_KRONA_KREPORT"],
              let outPath = env["LUNGFISH_KRONA_OUT"] else {
            throw XCTSkip("LUNGFISH_KRONA_KREPORT / LUNGFISH_KRONA_OUT not set")
        }
        let tag = env["LUNGFISH_KRONA_TAG"] ?? "run"
        let outDir = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let tree: TaxonTree
        if kreportPath.hasSuffix(".sqlite") {
            let db = try Kraken2Database(at: URL(fileURLWithPath: kreportPath))
            let sample = try XCTUnwrap(try db.fetchSamples().first?.sample)
            tree = try db.fetchTree(sample: sample)
        } else {
            tree = try KreportParser.parse(url: URL(fileURLWithPath: kreportPath))
        }
        let side: CGFloat = 900
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let layout = SunburstLayout(tree: tree, bounds: bounds)
        let segments = layout.computeSegments()

        var lines: [String] = []
        lines.append("totalReads=\(tree.totalReads) classified=\(tree.classifiedReads) unclassified=\(tree.unclassifiedReads) rootClade=\(tree.root.readsClade) rootDirect=\(tree.root.readsDirect)")
        lines.append("segments=\(segments.count) rings=\(Set(segments.map(\.ring)).sorted())")
        lines.append("ring\ttaxid\trank\tdepth\tname\tclade\tdirect\tpctTotal\tpctClassified\tstartDeg\tendDeg\tspanDeg\texpectedSpanDeg\tinnerR\touterR\tother")

        // Map node -> segment for nesting checks
        var segmentByNode: [ObjectIdentifier: SunburstSegment] = [:]
        for s in segments where !s.isOther {
            segmentByNode[ObjectIdentifier(s.node)] = s
        }
        let rootSpan: CGFloat = 360
        var violations: [String] = []
        for s in segments {
            let node = s.node
            let pctTotal = tree.totalReads > 0 ? Double(node.readsClade) / Double(tree.totalReads) * 100 : 0
            let pctClass = tree.classifiedReads > 0 ? Double(node.readsClade) / Double(tree.classifiedReads) * 100 : 0
            // Expected span: clade / root clade * 360 (the recursive product collapses to this)
            let expected = s.isOther ? -1 : CGFloat(node.readsClade) / CGFloat(tree.root.readsClade) * rootSpan
            lines.append([
                "\(s.ring)", "\(node.taxId)", node.rank.code, "\(node.depth)", s.isOther ? "[Other under \(node.name)]" : node.name,
                "\(node.readsClade)", "\(node.readsDirect)",
                String(format: "%.4f", pctTotal), String(format: "%.4f", pctClass),
                String(format: "%.4f", s.startAngle * 180 / .pi), String(format: "%.4f", s.endAngle * 180 / .pi),
                String(format: "%.4f", s.angularSpanDegrees), String(format: "%.4f", expected),
                String(format: "%.1f", s.innerRadius), String(format: "%.1f", s.outerRadius), s.isOther ? "1" : "0",
            ].joined(separator: "\t"))

            if !s.isOther {
                if abs(s.angularSpanDegrees - expected) > 1e-6 {
                    violations.append("span mismatch \(node.name): \(s.angularSpanDegrees) vs \(expected)")
                }
                if let parent = node.parent, let ps = segmentByNode[ObjectIdentifier(parent)] {
                    if s.startAngle < ps.startAngle - 1e-9 || s.endAngle > ps.endAngle + 1e-9 {
                        violations.append("not nested \(node.name) in \(parent.name)")
                    }
                    if s.ring != ps.ring + 1 {
                        violations.append("ring skip \(node.name) ring \(s.ring) parent \(parent.name) ring \(ps.ring)")
                    }
                } else if let parent = node.parent, parent !== tree.root {
                    violations.append("orphan drawn \(node.name): parent \(parent.name) not drawn")
                }
            }
        }
        // Children mass check per drawn parent
        for s in segments where !s.isOther {
            let childSum = s.node.children.reduce(0) { $0 + $1.readsClade }
            if childSum + s.node.readsDirect != s.node.readsClade {
                violations.append("mass \(s.node.name): clade \(s.node.readsClade) != direct \(s.node.readsDirect) + children \(childSum)")
            }
        }
        lines.append("violations=\(violations.count)")
        lines.append(contentsOf: violations.prefix(50))
        try lines.joined(separator: "\n").write(
            to: outDir.appendingPathComponent("wedges-\(tag).tsv"), atomically: true, encoding: .utf8)

        // Render at 2x (HiDPI) through the real view
        let view = TaxonomySunburstView(frame: bounds)
        view.appearance = NSAppearance(named: .aqua)
        view.tree = tree
        try render(view, scale: 2, to: outDir.appendingPathComponent("sunburst-\(tag).png"))

        // Drilled into Pseudomonadati if present
        if let node = tree.node(taxId: 3379134) {
            view.centerNode = node
            try render(view, scale: 2, to: outDir.appendingPathComponent("sunburst-\(tag)-pseudomonadati.png"))
        }
        // Drilled into Eukaryota
        if let node = tree.node(taxId: 2759) {
            view.centerNode = node
            try render(view, scale: 2, to: outDir.appendingPathComponent("sunburst-\(tag)-eukaryota.png"))
        }
    }

    func testRenderControllerAndSmallSizes() throws {
        let env = ProcessInfo.processInfo.environment
        guard let resultPath = env["LUNGFISH_KRONA_RESULT_DIR"],
              let outPath = env["LUNGFISH_KRONA_OUT"] else {
            throw XCTSkip("LUNGFISH_KRONA_RESULT_DIR / LUNGFISH_KRONA_OUT not set")
        }
        let tag = env["LUNGFISH_KRONA_TAG"] ?? "run"
        let outDir = URL(fileURLWithPath: outPath, isDirectory: true)
        let resultDir = URL(fileURLWithPath: resultPath, isDirectory: true)

        // Path 1: fresh result (kreport parse) through the controller.
        let result = try ClassificationResult.load(from: resultDir)
        let vc = TaxonomyViewController()
        vc.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 760)
        vc.view.appearance = NSAppearance(named: .aqua)
        vc.configure(result: result)
        vc.view.layoutSubtreeIfNeeded()
        try render(vc.view, scale: 2, to: outDir.appendingPathComponent("controller-\(tag)-kreport.png"))

        // Path 2: reopened result (sqlite) through the controller.
        let db = try Kraken2Database(at: resultDir.appendingPathComponent("kraken2.sqlite"))
        let vc2 = TaxonomyViewController()
        vc2.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 760)
        vc2.view.appearance = NSAppearance(named: .aqua)
        vc2.batchURL = resultDir
        vc2.configureFromDatabase(db)
        vc2.view.layoutSubtreeIfNeeded()
        try render(vc2.view, scale: 2, to: outDir.appendingPathComponent("controller-\(tag)-sqlite.png"))

        // Bare view at small and non-square sizes.
        for (w, h) in [(380, 520), (300, 300), (640, 420)] {
            let view = TaxonomySunburstView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            view.appearance = NSAppearance(named: .aqua)
            view.tree = result.tree
            try render(view, scale: 2, to: outDir.appendingPathComponent("sunburst-\(tag)-\(w)x\(h).png"))
        }
    }

    private func render(_ view: NSView, scale: CGFloat, to url: URL) throws {
        let w = Int(view.bounds.width * scale)
        let h = Int(view.bounds.height * scale)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
