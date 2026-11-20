// RNASeqCellMapSelectionTests.swift - The one membership function of a cell map's selection (Phase 5.5 lane CM-SELECT-CLI)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Check X3 of the plan for the function both callers share (5.5 S2): a point on an edge and on a vertex, a self-crossing
// polygon, a point that lies on opposite sides of an edge as a Double and as a Float32, a selection that spans two
// samples, the label form, and the grid path against the plain rule for every point. The time at 1,000,000 cells runs only
// with LUNGFISH_PERF_BENCH=1, as the raster bench does.

import Foundation
import XCTest
@testable import LungfishIO

final class RNASeqCellMapSelectionTests: XCTestCase {
    typealias Selection = RNASeqCellMapSelection
    typealias Vertex = RNASeqCellMapSelection.Vertex

    static let square = [Vertex(x: 0, y: 0), Vertex(x: 10, y: 0), Vertex(x: 10, y: 10), Vertex(x: 0, y: 10)]

    func vertices(_ pairs: [(Float32, Float32)]) -> [Vertex] { pairs.map { Vertex(x: $0.0, y: $0.1) } }

    func mask(_ points: [(Float32, Float32)], _ polygon: [Vertex]) -> [Bool] {
        Selection.mask(x: ContiguousArray(points.map(\.0)), y: ContiguousArray(points.map(\.1)), rule: .polygon(polygon))
    }

    /// The rule of the format page in Double from Double points, which no caller uses. The test shows where it differs.
    func containsAsDouble(_ px: Double, _ py: Double, _ polygon: [(Double, Double)]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let (xi, yi) = polygon[i], (xj, yj) = polygon[j]
            if (yi > py) != (yj > py) && px < (xj - xi) * (py - yi) / (yj - yi) + xi { inside.toggle() }
            j = i
        }
        return inside
    }

    // MARK: - Edges, vertices and crossings

    /// A point on the left or bottom edge, or on the vertex where they meet, is inside, and one on the right or top edge,
    /// or on any other vertex, is outside. That is what the one rule gives, and the grid path gives the same.
    func testAPointOnAnEdgeOrAVertexResolvesByTheOneRule() {
        let cases: [((Float32, Float32), Bool, String)] = [
            ((0, 5), true, "the left edge"), ((10, 5), false, "the right edge"),
            ((5, 0), true, "the bottom edge"), ((5, 10), false, "the top edge"),
            ((0, 0), true, "the bottom left vertex"), ((10, 0), false, "the bottom right vertex"),
            ((10, 10), false, "the top right vertex"), ((0, 10), false, "the top left vertex"),
            ((5, 5), true, "the middle"), ((-0.001, 5), false, "just left of the left edge"),
        ]
        let found = mask(cases.map(\.0), Self.square)
        for (index, (point, expected, what)) in cases.enumerated() {
            XCTAssertEqual(found[index], expected, what)
            XCTAssertEqual(Selection.contains(x: point.0, y: point.1, polygon: Self.square), expected, what)
        }
    }

    /// A pentagram crosses itself. Under the even-odd rule its middle pentagon crosses two edges to the left and is
    /// outside, and its five points are inside.
    func testASelfCrossingPolygonHoldsWhatTheEvenOddRuleHolds() {
        let star = (0..<5).map { k -> Vertex in
            let angle = (90.0 + Double(k) * 144.0) * Double.pi / 180
            return Vertex(x: Float32(10 * cos(angle)), y: Float32(10 * sin(angle)))
        }
        XCTAssertFalse(Selection.contains(x: 0, y: 0, polygon: star), "the middle of a pentagram is outside under even-odd")
        XCTAssertTrue(Selection.contains(x: 0, y: 8, polygon: star), "the top point of the pentagram is inside")
        var points: [(Float32, Float32)] = []
        for i in -12...12 { for j in -12...12 { points.append((Float32(i), Float32(j))) } }
        let found = mask(points + [(0, 0), (0, 8)], star)
        XCTAssertEqual(found, (points + [(0, 0), (0, 8)]).map { Selection.contains(x: $0.0, y: $0.1, polygon: star) })
        XCTAssertFalse(found[points.count])
        XCTAssertTrue(found[points.count + 1])
    }

    /// The point (0.3, 0.1) lies left of the edge from (3, 1) to (0, 0) as two Doubles, where the rule's x is 3 * 0.1 =
    /// 0.30000000000000004, and right of it once each number is a Float32, where 0.3 reads 0.30000001192 and the x is
    /// 0.30000000447. The function takes Float32 points, as `coordinates(embedding:)` converts each REAL once, so the view
    /// and the CLI both see the Float32 answer.
    func testAPointOnOppositeSidesAsADoubleAndAsAFloat32ResolvesTheFloat32Way() {
        let polygon = [(3.0, 1.0), (0.0, 0.0), (-3.0, 1.0)]
        let (px, py) = (0.3, 0.1)
        XCTAssertTrue(containsAsDouble(px, py, polygon), "as Doubles the point is inside")
        XCTAssertFalse(containsAsDouble(Double(Float32(px)), Double(Float32(py)), polygon), "as Float32 values the point is outside")
        let float32 = polygon.map { Vertex(x: Float32($0.0), y: Float32($0.1)) }
        XCTAssertFalse(Selection.contains(x: Float32(px), y: Float32(py), polygon: float32))
        XCTAssertEqual(mask([(Float32(px), Float32(py))], float32), [false])
    }

    func testFewerThanThreeVerticesOrAVertexThatIsNotFiniteHoldsNoCell() {
        let points: [(Float32, Float32)] = [(5, 5), (0.5, 0.5), (1, 1)]
        XCTAssertEqual(mask(points, vertices([(0, 0), (10, 10)])), [false, false, false])
        XCTAssertEqual(mask(points, vertices([(0, 0), (10, 0), (10, .nan), (0, 10)])), [false, false, false])
        XCTAssertEqual(mask(points, vertices([(0, 0), (10, 0), (.infinity, 10), (0, 10)])), [false, false, false])
    }

    // MARK: - Samples and the label form

    /// Cells of two samples lie side by side. The function returns each sample's selected cell ids, rising, and never a
    /// cell with no coordinates.
    func testASelectionThatSpansTwoSamplesReturnsTheCellsOfEach() {
        let x: ContiguousArray<Float32> = [1, 2, 3, 20, 4, .nan, 5]
        let y: ContiguousArray<Float32> = [1, 2, 3, 20, 4, .nan, 5]
        let sample: ContiguousArray<UInt32> = [0, 1, 0, 1, 1, 0, 2]
        let found = Selection.select(x: x, y: y, sampleOfCell: sample, samples: 2, rule: .polygon(Self.square))
        XCTAssertEqual(found, [[1, 3], [2, 5]], "cell 4 lies outside, cell 6 has no coordinates and cell 7 names no sample place")
    }

    /// In the label form a cell is selected when it has coordinates and one of the chosen labels. A cell with label 0
    /// has none.
    func testTheLabelFormSelectsTheDrawnCellsOfTheChosenLabels() {
        let x: ContiguousArray<Float32> = [1, 2, .nan, 4, 5, 6]
        let y: ContiguousArray<Float32> = [1, 2, 3, 4, 5, 6]
        let labels: ContiguousArray<UInt32> = [1, 2, 1, 0, 3, 1]
        let sample: ContiguousArray<UInt32> = [0, 0, 0, 1, 1, 1]
        XCTAssertEqual(Selection.select(x: x, y: y, sampleOfCell: sample, samples: 2, rule: .labels(labels, chosen: [1, 3])), [[1], [5, 6]])
        XCTAssertEqual(Selection.mask(x: x, y: y, rule: .labels(labels, chosen: [0])), [false, false, false, false, false, false])
        XCTAssertEqual(Selection.mask(x: x, y: y, rule: .labels(labels, chosen: [])), [false, false, false, false, false, false])
    }

    // MARK: - The grid path equals the plain rule

    /// 12,000 points, a quarter of them on a coarse grid so that many lie on the edges and vertices of a polygon drawn on
    /// that grid, against a self-crossing star of 400 vertices, a polygon on the grid, a thin sliver and a lasso of 1,000
    /// vertices. Every point gets the plain rule's answer.
    func testTheGridPathEqualsThePlainRuleForEveryPoint() {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        var x = ContiguousArray<Float32>()
        var y = ContiguousArray<Float32>()
        for index in 0..<12_000 {
            if index % 4 == 0 {
                x.append(Float32(Int(next() * 41) - 20))
                y.append(Float32(Int(next() * 41) - 20))
            } else {
                x.append(Float32(next() * 44 - 22))
                y.append(Float32(next() * 44 - 22))
            }
        }
        x.append(.nan)
        y.append(3)
        let star = (0..<400).map { k -> Vertex in
            let angle = Double(k) * 2 * Double.pi * 137 / 400
            let radius = 6 + 14 * next()
            return Vertex(x: Float32(radius * cos(angle)), y: Float32(radius * sin(angle)))
        }
        let grid = vertices([(-10, -10), (10, -10), (10, 0), (0, 0), (0, 10), (-10, 10), (-10, 5), (5, 5), (5, -5), (-10, -5)])
        let sliver = vertices([(-20, -20), (20, 19.9), (20, 20)])
        let lasso = (0..<1_000).map { k -> Vertex in
            let angle = Double(k) * 2 * Double.pi / 1_000
            let radius = 12 + 3 * sin(7 * angle) + next()
            return Vertex(x: Float32(radius * cos(angle)), y: Float32(radius * sin(angle)))
        }
        for (polygon, what) in [(star, "star"), (grid, "grid"), (sliver, "sliver"), (lasso, "lasso"), (Self.square, "square")] {
            let found = Selection.mask(x: x, y: y, rule: .polygon(polygon))
            var differ = 0
            var held = 0
            for cell in x.indices {
                if found[cell] != Selection.contains(x: x[cell], y: y[cell], polygon: polygon) { differ += 1 }
                if found[cell] { held += 1 }
            }
            XCTAssertEqual(differ, 0, "the grid path and the plain rule differ on \(differ) points of the \(what)")
            XCTAssertGreaterThan(held, 0, "the \(what) holds some points")
            XCTAssertFalse(found[x.count - 1], "a point with no x is never inside the \(what)")
        }
    }

    // MARK: - The time at 1,000,000 cells

    /// The bar of check X3: 1,000,000 synthetic cells against a lasso of 1,000 vertices in under 50 ms. It runs only when
    /// LUNGFISH_PERF_BENCH=1 is set, so no gate runs it. The bar holds for an optimized build, as the packaged app and
    /// `lungfish-cli` are, so only such a build asserts it, and a Debug build prints its figures and says so.
    func testOneMillionCellsAgainstALassoOf1000Vertices() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LUNGFISH_PERF_BENCH"] == "1",
                          "Set LUNGFISH_PERF_BENCH=1 to time the membership function at 1,000,000 cells.")
        let count = 1_000_000
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Float32 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float32(state >> 40) / Float32(1 << 24)
        }
        var x = ContiguousArray<Float32>(repeating: 0, count: count)
        var y = ContiguousArray<Float32>(repeating: 0, count: count)
        for cell in 0..<count {
            let cluster = cell % 12
            x[cell] = Float32(cluster % 4) * 10 + (next() + next() + next() - 1.5) * Float32(1 + cluster % 3)
            y[cell] = Float32(cluster / 4) * 10 + (next() + next() + next() - 1.5) * Float32(1 + cluster % 2)
        }
        let lasso = (0..<1_000).map { k -> Vertex in
            let angle = Double(k) * 2 * Double.pi / 1_000
            let radius = 9 + 2 * sin(5 * angle)
            return Vertex(x: Float32(15 + radius * cos(angle)), y: Float32(10 + radius * sin(angle)))
        }
        var times: [Double] = []
        var held = 0
        for _ in 0..<11 {
            let start = DispatchTime.now().uptimeNanoseconds
            let found = Selection.mask(x: x, y: y, rule: .polygon(lasso))
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            held = found.reduce(0) { $1 ? $0 + 1 : $0 }
        }
        let sorted = times.sorted()
        let median = sorted[sorted.count / 2]
        print(String(format: "CM-SELECT-CLI membership bench: 1000000 cells, 1000 vertices, first %.1f ms, median %.1f ms, slowest %.1f ms, %d cells inside",
                     times[0], median, sorted.last ?? 0, held))
        #if DEBUG
        print("CM-SELECT-CLI membership bench: the 50 ms bar of check X3 applies to an optimized build, so this Debug build does not assert it.")
        #else
        XCTAssertLessThan(median, 50, "the membership of 1,000,000 cells stays under 50 ms (check X3)")
        #endif
    }
}
