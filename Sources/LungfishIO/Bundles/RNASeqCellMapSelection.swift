// RNASeqCellMapSelection.swift - The one membership function of a cell map's selection (Phase 5.5 lane CM-SELECT-CLI)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// One pure function decides the view's highlight, the count on screen and the cells `lungfish-cli rnaseq cell-map select`
// writes (5.5 S2, `docs/formats/rnaseq-cell-map.md`, The membership function). Both callers pass the Float32 arrays of
// `RNASeqCellMapDatabase.coordinates(embedding:)`, each REAL converted once, and Float32 vertices, so a point that lies on
// one side of an edge as a Double and on the other as a Float32 resolves the same for both. The function never simplifies
// a polygon. It holds no state and touches no file.

import Foundation

public enum RNASeqCellMapSelection {
    /// The fewest and the most vertices `cell-map select` takes. At 1,000 the polygon prints in about 30 KB of argv.
    public static let minimumVertices = 3
    public static let maximumVertices = 1_000

    public struct Vertex: Equatable, Hashable, Sendable {
        public var x: Float32
        public var y: Float32

        public init(x: Float32, y: Float32) {
            self.x = x
            self.y = y
        }
    }

    /// How cells are chosen. `labels` holds the label number of each cell in cell order, 0 for a cell with no label, as
    /// `RNASeqCellMapDatabase.cellLabels(labelSet:)` returns it, and `chosen` the label numbers selected.
    public enum Rule: Equatable, Sendable {
        case polygon([Vertex])
        case labels(ContiguousArray<UInt32>, chosen: Set<UInt32>)
    }

    /// The selected cells of each sample place, cell ids from 1, rising. `sampleOfCell` holds each cell's sample place from
    /// 0 in cell order, and a place at or past `samples` is never selected. A cell with no coordinates holds NaN and is
    /// never selected.
    public static func select(
        x: ContiguousArray<Float32>, y: ContiguousArray<Float32>, sampleOfCell: ContiguousArray<UInt32>, samples: Int, rule: Rule
    ) -> [[Int]] {
        var selected = [[Int]](repeating: [], count: max(0, samples))
        let inside = mask(x: x, y: y, rule: rule)
        for cell in 0..<min(inside.count, sampleOfCell.count) where inside[cell] {
            let place = Int(sampleOfCell[cell])
            if place < selected.count { selected[place].append(cell + 1) }
        }
        return selected
    }

    /// Whether each cell is selected, in cell order, over the cells that both arrays hold.
    public static func mask(x: ContiguousArray<Float32>, y: ContiguousArray<Float32>, rule: Rule) -> [Bool] {
        switch rule {
        case .polygon(let vertices): return polygonMask(x: x, y: y, vertices: vertices)
        case .labels(let labels, let chosen): return labelMask(x: x, y: y, labels: labels, chosen: chosen)
        }
    }

    /// The plain even-odd rule for one point, which every faster path equals. The polygon closes from its last vertex to
    /// its first. For each edge from vertex j to vertex i the point crosses when `(yi > py) != (yj > py)` and
    /// `px < (xj - xi) * (py - yi) / (yj - yi) + xi`, both in Double from the Float32 values, and it is inside when it
    /// crosses an odd number of edges. A polygon of fewer than 3 vertices, or one with a vertex that is not finite,
    /// holds no point.
    public static func contains(x px: Float32, y py: Float32, polygon vertices: [Vertex]) -> Bool {
        guard let edges = edges(of: vertices) else { return false }
        let x = Double(px)
        let y = Double(py)
        var inside = false
        for edge in edges where crosses(edge, x, y) { inside.toggle() }
        return inside
    }

    // MARK: - The label form

    static func labelMask(x: ContiguousArray<Float32>, y: ContiguousArray<Float32>, labels: ContiguousArray<UInt32>, chosen: Set<UInt32>) -> [Bool] {
        let count = min(x.count, y.count, labels.count)
        var inside = [Bool](repeating: false, count: min(x.count, y.count))
        guard let top = chosen.max(), top > 0 else { return inside }
        var wanted = [Bool](repeating: false, count: Int(top) + 1)
        for label in chosen where label > 0 { wanted[Int(label)] = true }
        for cell in 0..<count {
            let label = Int(labels[cell])
            inside[cell] = label < wanted.count && wanted[label] && !x[cell].isNaN && !y[cell].isNaN
        }
        return inside
    }

    // MARK: - The polygon form

    /// One edge from vertex j to vertex i, in Double. An edge whose two ends share a y never crosses, so it is left out.
    struct Edge {
        var xi: Double, yi: Double, xj: Double, yj: Double
    }

    /// The edges of the closed polygon, or nil for a polygon that holds no point.
    static func edges(of vertices: [Vertex]) -> [Edge]? {
        guard vertices.count >= minimumVertices, vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        var edges: [Edge] = []
        edges.reserveCapacity(vertices.count)
        var j = vertices.count - 1
        for i in vertices.indices {
            let edge = Edge(xi: Double(vertices[i].x), yi: Double(vertices[i].y), xj: Double(vertices[j].x), yj: Double(vertices[j].y))
            if edge.yi != edge.yj { edges.append(edge) }
            j = i
        }
        return edges
    }

    /// The x where the edge meets the line at `py`, written as the rule writes it. For a fixed edge each rounded step is
    /// monotone in `py`, so the value is monotone in `py`, which the bin test below relies on.
    @inline(__always)
    static func edgeX(_ edge: Edge, _ py: Double) -> Double {
        (edge.xj - edge.xi) * (py - edge.yi) / (edge.yj - edge.yi) + edge.xi
    }

    @inline(__always)
    static func crosses(_ edge: Edge, _ px: Double, _ py: Double) -> Bool {
        (edge.yi > py) != (edge.yj > py) && px < edgeX(edge, py)
    }

    /// The bin of `value` along one axis. Each step is monotone in `value`, so a value at or above another never takes a
    /// lower bin.
    @inline(__always)
    static func bin(_ value: Double, origin: Double, scale: Double, bins: Int) -> Int {
        let place = (value - origin) * scale
        if !(place > 0) { return 0 }
        if place >= Double(bins) { return bins - 1 }
        return Int(place)
    }

    /// The grid path. Points with finite coordinates go into square bins over their bounds. Each row of bins lists the
    /// edges whose y span reaches it, and an edge that a row does not list crosses no point of that row. A bin whose
    /// points every listed edge crosses alike, judged at the bin's own lowest and highest x and y, takes all its points or
    /// none, and any other bin tests each point by the plain rule over its row's edges. So the result equals `contains`
    /// for every point. A point that is not finite is never inside.
    static func polygonMask(x: ContiguousArray<Float32>, y: ContiguousArray<Float32>, vertices: [Vertex]) -> [Bool] {
        let count = min(x.count, y.count)
        var inside = [Bool](repeating: false, count: count)
        guard let edges = edges(of: vertices), !edges.isEmpty else { return inside }

        var lowX = Double.infinity, highX = -Double.infinity, lowY = Double.infinity, highY = -Double.infinity
        var finite = 0
        for cell in 0..<count where x[cell].isFinite && y[cell].isFinite {
            let px = Double(x[cell]), py = Double(y[cell])
            lowX = min(lowX, px)
            highX = max(highX, px)
            lowY = min(lowY, py)
            highY = max(highY, py)
            finite += 1
        }
        guard finite > 0 else { return inside }
        let side = max(1, min(512, Int((Double(finite) / 16).squareRoot())))
        let scaleX = highX > lowX ? Double(side) / (highX - lowX) : 0
        let scaleY = highY > lowY ? Double(side) / (highY - lowY) : 0
        let binCount = side * side

        var binOfCell = [Int32](repeating: -1, count: count)
        var starts = [Int](repeating: 0, count: binCount + 1)
        var binLowX = [Float32](repeating: .infinity, count: binCount)
        var binHighX = [Float32](repeating: -.infinity, count: binCount)
        var binLowY = [Float32](repeating: .infinity, count: binCount)
        var binHighY = [Float32](repeating: -.infinity, count: binCount)
        for cell in 0..<count where x[cell].isFinite && y[cell].isFinite {
            let px = x[cell], py = y[cell]
            let row = bin(Double(py), origin: lowY, scale: scaleY, bins: side)
            let column = bin(Double(px), origin: lowX, scale: scaleX, bins: side)
            let place = row * side + column
            binOfCell[cell] = Int32(place)
            starts[place + 1] += 1
            binLowX[place] = min(binLowX[place], px)
            binHighX[place] = max(binHighX[place], px)
            binLowY[place] = min(binLowY[place], py)
            binHighY[place] = max(binHighY[place], py)
        }
        for place in 0..<binCount { starts[place + 1] += starts[place] }
        var order = [Int32](repeating: 0, count: finite)
        var next = starts
        for cell in 0..<count where binOfCell[cell] >= 0 {
            let place = Int(binOfCell[cell])
            order[next[place]] = Int32(cell)
            next[place] += 1
        }

        var rowEdges = [[Int32]](repeating: [], count: side)
        for (index, edge) in edges.enumerated() {
            let first = bin(min(edge.yi, edge.yj), origin: lowY, scale: scaleY, bins: side)
            let last = bin(max(edge.yi, edge.yj), origin: lowY, scale: scaleY, bins: side)
            for row in first...last { rowEdges[row].append(Int32(index)) }
        }

        for place in 0..<binCount where starts[place + 1] > starts[place] {
            let listed = rowEdges[place / side]
            let pxLow = Double(binLowX[place]), pxHigh = Double(binHighX[place])
            let pyLow = Double(binLowY[place]), pyHigh = Double(binHighY[place])
            var odd = false
            var mixed = false
            for index in listed {
                let edge = edges[Int(index)]
                let iLow = edge.yi > pyLow, jLow = edge.yj > pyLow
                guard iLow == (edge.yi > pyHigh), jLow == (edge.yj > pyHigh) else {
                    mixed = true
                    break
                }
                guard iLow != jLow else { continue }
                let atLow = edgeX(edge, pyLow), atHigh = edgeX(edge, pyHigh)
                if pxHigh < min(atLow, atHigh) {
                    odd.toggle()
                } else if !(pxLow >= max(atLow, atHigh)) {
                    mixed = true
                    break
                }
            }
            let range = starts[place]..<starts[place + 1]
            if mixed {
                for slot in range {
                    let cell = Int(order[slot])
                    let px = Double(x[cell]), py = Double(y[cell])
                    var crossed = false
                    for index in listed where crosses(edges[Int(index)], px, py) { crossed.toggle() }
                    inside[cell] = crossed
                }
            } else if odd {
                for slot in range { inside[Int(order[slot])] = true }
            }
        }
        return inside
    }
}
