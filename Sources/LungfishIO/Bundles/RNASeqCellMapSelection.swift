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

    /// The grid path. Points with finite coordinates go into square bins over their bounds, and each bin keeps the lowest
    /// and highest x and y of its own points. For every point the plain rule counts the edges with
    /// `(yi > py) != (yj > py)`, that is `py` in `[yLow, yHigh)`, and `px < edgeX`. The path sorts each edge, bin by bin,
    /// into one of three answers that hold for every point of the bin, and the bin keeps the parity of the first:
    /// - it crosses every point, when every point's y lies in its span and every point lies left of it;
    /// - it crosses no point, when no point's y lies in its span or every point lies on or right of it;
    /// - it may cross some, and the bin lists it, so each point of the bin tests it by `crosses`.
    ///
    /// A point is then inside when the bin's parity and the crossings of the listed edges are odd, which is the plain
    /// rule's count, so the result equals `contains` for every point. A point that is not finite is never inside.
    ///
    /// Where an edge lies is judged from `edgeX` at the ends of the y range in question, clamped to the edge's span. For
    /// a fixed edge `edgeX` and `bin` are monotone (`edgeX(_:_:)`, `bin(_:origin:scale:bins:)`), so `edgeX` at any y of the
    /// range lies between those two values, and a point whose column is below the column of the lower value lies left of
    /// every such x, and one whose column is above the column of the higher value lies right of every such x. An edge
    /// whose span covers every point of a row and that lies wholly right of a bin flips the parity of every bin to its
    /// left in one pass along the row, so a row costs its edges plus its bins, not their product.
    static func polygonMask(x: ContiguousArray<Float32>, y: ContiguousArray<Float32>, vertices: [Vertex]) -> [Bool] {
        let count = min(x.count, y.count)
        var inside = [Bool](repeating: false, count: count)
        guard let edges = edges(of: vertices), !edges.isEmpty else { return inside }

        var lowX = Double.infinity, highX = -Double.infinity, lowY = Double.infinity, highY = -Double.infinity
        var finite = 0
        x.withUnsafeBufferPointer { xs in
            y.withUnsafeBufferPointer { ys in
                for cell in 0..<count where xs[cell].isFinite && ys[cell].isFinite {
                    let px = Double(xs[cell]), py = Double(ys[cell])
                    lowX = min(lowX, px)
                    highX = max(highX, px)
                    lowY = min(lowY, py)
                    highY = max(highY, py)
                    finite += 1
                }
            }
        }
        guard finite > 0 else { return inside }
        let side = max(1, min(gridSideLimit, Int((Double(finite) / pointsPerBin).squareRoot())))
        let scaleX = highX > lowX ? Double(side) / (highX - lowX) : 0
        let scaleY = highY > lowY ? Double(side) / (highY - lowY) : 0
        let binCount = side * side

        var binOfCell = [Int32](repeating: -1, count: count)
        var boxes = [Box](repeating: Box(), count: binCount)
        x.withUnsafeBufferPointer { xs in
            y.withUnsafeBufferPointer { ys in
                binOfCell.withUnsafeMutableBufferPointer { places in
                    boxes.withUnsafeMutableBufferPointer { box in
                        for cell in 0..<count where xs[cell].isFinite && ys[cell].isFinite {
                            let px = xs[cell], py = ys[cell]
                            let row = bin(Double(py), origin: lowY, scale: scaleY, bins: side)
                            let column = bin(Double(px), origin: lowX, scale: scaleX, bins: side)
                            let place = row * side + column
                            places[cell] = Int32(place)
                            box[place].lowX = min(box[place].lowX, px)
                            box[place].highX = max(box[place].highX, px)
                            box[place].lowY = min(box[place].lowY, py)
                            box[place].highY = max(box[place].highY, py)
                        }
                    }
                }
            }
        }

        // A row that an edge's span does not reach holds no point whose y lies in that span, since `bin` is monotone.
        var rowEdges = [[Int32]](repeating: [], count: side)
        for (index, edge) in edges.enumerated() {
            let first = bin(min(edge.yi, edge.yj), origin: lowY, scale: scaleY, bins: side)
            let last = bin(max(edge.yi, edge.yj), origin: lowY, scale: scaleY, bins: side)
            for row in first...last { rowEdges[row].append(Int32(index)) }
        }

        var odd = [Bool](repeating: false, count: binCount)
        var listStart = [Int](repeating: 0, count: binCount + 1)
        var listed: [Int32] = []
        var pairs: [(column: Int, edge: Int32)] = []
        var flip = [Bool](repeating: false, count: side + 1)
        var perColumn = [Int](repeating: 0, count: side + 1)
        for row in 0..<side {
            let base = row * side
            var rowLowY = Float32.infinity, rowHighY = -Float32.infinity
            for place in base..<(base + side) {
                rowLowY = min(rowLowY, boxes[place].lowY)
                rowHighY = max(rowHighY, boxes[place].highY)
            }
            guard rowLowY <= rowHighY else {
                for place in base..<(base + side) { listStart[place] = listed.count }
                continue
            }
            let rowLow = Double(rowLowY), rowHigh = Double(rowHighY)
            pairs.removeAll(keepingCapacity: true)
            for column in 0...side { flip[column] = false }

            for index in rowEdges[row] {
                let edge = edges[Int(index)]
                let yLow = min(edge.yi, edge.yj), yHigh = max(edge.yi, edge.yj)
                let low = max(yLow, rowLow), high = min(yHigh, rowHigh)
                guard low <= high else { continue }
                let atLow = edgeX(edge, low), atHigh = edgeX(edge, high)
                // Every point of a column before `first` lies left of the edge, and every point of a column after `last`
                // lies on or right of it, which never crosses.
                let first = bin(min(atLow, atHigh), origin: lowX, scale: scaleX, bins: side)
                let last = bin(max(atLow, atHigh), origin: lowX, scale: scaleX, bins: side)
                if yLow <= rowLow && rowHigh < yHigh {
                    flip[first].toggle()
                } else {
                    for column in 0..<first {
                        let place = base + column
                        let box = boxes[place]
                        guard !box.isEmpty else { continue }
                        let pyLow = Double(box.lowY), pyHigh = Double(box.highY)
                        if yLow <= pyLow && pyHigh < yHigh {
                            odd[place].toggle()
                        } else if !(pyHigh < yLow || pyLow >= yHigh) {
                            pairs.append((column, index))
                        }
                    }
                }
                for column in first...last {
                    let place = base + column
                    let box = boxes[place]
                    guard !box.isEmpty else { continue }
                    let pyLow = Double(box.lowY), pyHigh = Double(box.highY)
                    let lowHere = max(yLow, pyLow), highHere = min(yHigh, pyHigh)
                    guard lowHere <= highHere else { continue }
                    let a = edgeX(edge, lowHere), b = edgeX(edge, highHere)
                    if Double(box.highX) < min(a, b) {
                        if yLow <= pyLow && pyHigh < yHigh { odd[place].toggle() } else { pairs.append((column, index)) }
                    } else if !(Double(box.lowX) >= max(a, b)) {
                        pairs.append((column, index))
                    }
                }
            }

            // A column takes the flips of every full-span edge whose `first` lies past it.
            var running = false
            for column in stride(from: side - 1, through: 0, by: -1) {
                if flip[column + 1] { running.toggle() }
                if running { odd[base + column].toggle() }
            }

            // The listed edges of the row, bin by bin in column order.
            for column in 0...side { perColumn[column] = 0 }
            for pair in pairs { perColumn[pair.column + 1] += 1 }
            for column in 0..<side { perColumn[column + 1] += perColumn[column] }
            let start = listed.count
            for column in 0..<side { listStart[base + column] = start + perColumn[column] }
            listed.append(contentsOf: repeatElement(0, count: pairs.count))
            for pair in pairs {
                listed[start + perColumn[pair.column]] = pair.edge
                perColumn[pair.column] += 1
            }
        }
        listStart[binCount] = listed.count

        // One byte a bin for the pass over the points: bit 0 the parity, bit 1 set when the bin lists an edge.
        var answer = [UInt8](repeating: 0, count: binCount)
        for place in 0..<binCount {
            answer[place] = (listStart[place] < listStart[place + 1] ? 2 : 0) | (odd[place] ? 1 : 0)
        }
        x.withUnsafeBufferPointer { xs in
            y.withUnsafeBufferPointer { ys in
                binOfCell.withUnsafeBufferPointer { places in
                    inside.withUnsafeMutableBufferPointer { out in
                        for cell in 0..<count {
                            let place = Int(places[cell])
                            guard place >= 0 else { continue }
                            let kind = answer[place]
                            guard kind >= 2 else {
                                out[cell] = kind == 1
                                continue
                            }
                            var crossed = kind == 3
                            let px = Double(xs[cell]), py = Double(ys[cell])
                            for slot in listStart[place]..<listStart[place + 1] where crosses(edges[Int(listed[slot])], px, py) {
                                crossed.toggle()
                            }
                            out[cell] = crossed
                        }
                    }
                }
            }
        }
        return inside
    }

    /// The lowest and highest x and y of the points in one bin, in one place so that a point touches one cache line. An
    /// empty bin keeps the infinities it starts with.
    struct Box {
        var lowX = Float32.infinity, highX = -Float32.infinity, lowY = Float32.infinity, highY = -Float32.infinity
        var isEmpty: Bool { !(lowX <= highX) }
    }

    /// About this many finite points share a bin, and a side holds at most `gridSideLimit` bins.
    static let pointsPerBin: Double = 16
    static let gridSideLimit = 512
}
