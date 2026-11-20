// RNASeqEmbeddingRaster.swift - The CPU raster of an embedding and its hit-test grid (Phase 5.5 lane CM-VIEW)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The plot is drawn off the main actor into a buffer of RGBA8 words, one word a pixel, with integer writes and no
// CoreGraphics (5.5 V1 and O6). A point is a filled disc in its colour, written over what came before, so the draw
// order decides which point is on top. The same pass keeps each point's pixel, and a uniform grid of those pixels
// answers a hover with the point on top, the last one drawn, so hover and drawing agree (SWIFT A1). Nothing here is a
// number on screen. The raster places what `cellmap.sqlite` holds and counts nothing.

import Foundation

/// The colours of the plot as RGBA8 words, red in the lowest byte, so a word stored on a little-endian Mac lays out
/// red, green, blue and alpha. Index 0 to 18 are the label slots, 19 is the grey of zeros and of cells with no label,
/// and 20 onward are the 256 steps of the continuous scale.
public enum RNASeqEmbeddingPalette {
    public static let labelSlots = 19
    public static let greyIndex: UInt16 = 19
    public static let gradientBase: UInt16 = 20
    public static let gradientSteps = 256
    public static var count: Int { Int(gradientBase) + gradientSteps }

    public typealias RGB = (red: UInt8, green: UInt8, blue: UInt8)

    /// Slots 0 to 18 of `PhylumPalette.phylumColors` with their dark values
    /// (`Sources/LungfishKit/TaxonomyPhylumPalette.swift`). Slot 19, the overflow grey, is left out, because it would read
    /// as the grey of zeros (5.5 V3). `RNASeqCellMapViewModelTests` checks the copy against LungfishKit.
    public static let labelColours: [(light: RGB, dark: RGB)] = [
        ((0x4A, 0x90, 0xD9), (0x6B, 0xAB, 0xEF)), ((0xE8, 0x85, 0x3D), (0xF0, 0xA0, 0x60)),
        ((0x4C, 0xAF, 0x50), (0x6E, 0xCF, 0x72)), ((0xD6, 0x45, 0x41), (0xE8, 0x6E, 0x6A)),
        ((0x26, 0xA6, 0x9A), (0x4C, 0xC8, 0xBC)), ((0xF2, 0xB8, 0x25), (0xF5, 0xCA, 0x55)),
        ((0x9C, 0x5B, 0xB5), (0xB8, 0x80, 0xD0)), ((0xE5, 0x73, 0x99), (0xF0, 0x9A, 0xB8)),
        ((0x00, 0xAC, 0xC1), (0x33, 0xCC, 0xDD)), ((0xA0, 0x78, 0x55), (0xC0, 0x98, 0x78)),
        ((0x79, 0x86, 0xCB), (0x9A, 0xA4, 0xE0)), ((0xEF, 0x6C, 0x6C), (0xF5, 0x90, 0x90)),
        ((0x8B, 0xC3, 0x4A), (0xA8, 0xD8, 0x70)), ((0x7B, 0x1F, 0xA2), (0xA0, 0x50, 0xC8)),
        ((0xFF, 0xB7, 0x4D), (0xFF, 0xCC, 0x80)), ((0x00, 0x96, 0x88), (0x33, 0xB8, 0xAA)),
        ((0x60, 0x7D, 0x8B), (0x8A, 0xA0, 0xAC)), ((0xC2, 0x18, 0x5B), (0xE0, 0x40, 0x80)),
        ((0xCD, 0xDC, 0x39), (0xDB, 0xE8, 0x68)),
    ]

    /// The light grey that zeros and unlabelled cells take, drawn first (5.5 V3).
    public static let zeroGrey: (light: RGB, dark: RGB) = ((0xD4, 0xD4, 0xD4), (0x5C, 0x5C, 0x5C))

    /// Nine stops of viridis, a perceptually even scale that reads in the common forms of colour blindness.
    static let viridis: [RGB] = [
        (0x44, 0x01, 0x54), (0x48, 0x28, 0x78), (0x3E, 0x4A, 0x89), (0x31, 0x68, 0x8E), (0x26, 0x82, 0x8E),
        (0x1F, 0x9E, 0x89), (0x35, 0xB7, 0x79), (0x6D, 0xCD, 0x59), (0xFD, 0xE7, 0x25),
    ]

    public static func word(_ colour: RGB) -> UInt32 {
        UInt32(colour.red) | UInt32(colour.green) << 8 | UInt32(colour.blue) << 16 | 0xFF00_0000
    }

    /// Step `step` of 0 to 255 of the scale, between two stops by whole-number arithmetic.
    public static func gradient(_ step: Int) -> RGB {
        let clamped = min(max(step, 0), gradientSteps - 1)
        let scaled = clamped * (viridis.count - 1)
        let stop = min(scaled / (gradientSteps - 1), viridis.count - 2)
        let part = scaled - stop * (gradientSteps - 1)
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(Int(a) + (Int(b) - Int(a)) * part / (gradientSteps - 1))
        }
        let low = viridis[stop], high = viridis[stop + 1]
        return (mix(low.red, high.red), mix(low.green, high.green), mix(low.blue, high.blue))
    }

    /// Every word of the palette for a light or a dark appearance.
    public static func words(dark: Bool) -> [UInt32] {
        var words = labelColours.map { word(dark ? $0.dark : $0.light) }
        words.append(word(dark ? zeroGrey.dark : zeroGrey.light))
        words += (0..<gradientSteps).map { word(gradient($0)) }
        return words
    }

    /// The palette index of label slot `slot`, past 19 labels the colours repeat (5.5 V3).
    public static func labelIndex(_ slot: Int) -> UInt16 { UInt16(slot % labelSlots) }
}

/// The part of the embedding's plane that the plot shows, in the embedding's own units.
public struct RNASeqEmbeddingWindow: Equatable, Sendable {
    public var minX: Float32, minY: Float32, maxX: Float32, maxY: Float32

    public init(minX: Float32, minY: Float32, maxX: Float32, maxY: Float32) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    /// The smallest window that holds every drawn cell, or a unit square when none is drawn.
    public static func fit(x: ContiguousArray<Float32>, y: ContiguousArray<Float32>, order: ContiguousArray<UInt32>) -> Self {
        var window = Self(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)
        for cell in order {
            let px = x[Int(cell)], py = y[Int(cell)]
            guard px.isFinite, py.isFinite else { continue }
            window.minX = min(window.minX, px)
            window.maxX = max(window.maxX, px)
            window.minY = min(window.minY, py)
            window.maxY = max(window.maxY, py)
        }
        guard window.minX <= window.maxX else { return Self(minX: 0, minY: 0, maxX: 1, maxY: 1) }
        if window.maxX == window.minX { window.minX -= 0.5; window.maxX += 0.5 }
        if window.maxY == window.minY { window.minY -= 0.5; window.maxY += 0.5 }
        return window
    }
}

/// From the embedding's units to pixels, one scale for both axes so neither is stretched, centred, with a margin of
/// `pad` pixels so a disc at the edge is whole. Rows count down from the top.
public struct RNASeqEmbeddingMapping: Equatable, Sendable {
    public let scale: Float32
    public let originX: Float32
    public let originY: Float32
    public let window: RNASeqEmbeddingWindow

    public init(window: RNASeqEmbeddingWindow, width: Int, height: Int, pad: Int) {
        let usableX = Float32(max(width - 2 * pad, 1)), usableY = Float32(max(height - 2 * pad, 1))
        let spanX = window.maxX - window.minX, spanY = window.maxY - window.minY
        let scale = min(usableX / spanX, usableY / spanY)
        self.scale = scale
        self.originX = Float32(pad) + (usableX - spanX * scale) / 2
        self.originY = Float32(pad) + (usableY - spanY * scale) / 2
        self.window = window
    }

    /// The pixel column and row of a point as floats, NaN for a cell left out.
    @inline(__always)
    public func pixel(x: Float32, y: Float32) -> (column: Float32, row: Float32) {
        ((x - window.minX) * scale + originX, (window.maxY - y) * scale + originY)
    }

    /// The point of the plane under a pixel.
    public func point(column: Float32, row: Float32) -> (x: Float32, y: Float32) {
        ((column - originX) / scale + window.minX, window.maxY - (row - originY) / scale)
    }
}

/// What one raster draws. It holds the arrays it was given, which copy on write, so a request costs no copy.
public struct RNASeqEmbeddingRasterInput: Sendable {
    /// Dimensions 1 and 2 of the embedding in cell order, NaN for a cell left out (5.5 V4).
    public var x: ContiguousArray<Float32>
    public var y: ContiguousArray<Float32>
    /// The cells to draw, from 0, first drawn first (5.5 V3).
    public var order: ContiguousArray<UInt32>
    /// The palette index of each cell, in cell order.
    public var colour: ContiguousArray<UInt16>
    public var palette: [UInt32]
    public var width: Int
    public var height: Int
    /// The disc's radius in pixels. A radius of 0 draws one pixel.
    public var radius: Int
    public var window: RNASeqEmbeddingWindow

    public init(x: ContiguousArray<Float32>, y: ContiguousArray<Float32>, order: ContiguousArray<UInt32>, colour: ContiguousArray<UInt16>,
                palette: [UInt32], width: Int, height: Int, radius: Int, window: RNASeqEmbeddingWindow) {
        self.x = x
        self.y = y
        self.order = order
        self.colour = colour
        self.palette = palette
        self.width = width
        self.height = height
        self.radius = radius
        self.window = window
    }

    public var pad: Int { radius + 1 }
}

/// A uniform grid of the drawn points' pixels. Each bin lists the draw ranks of its points, rising, so the last one a
/// hover finds within reach is the point on top.
public struct RNASeqEmbeddingGrid: Sendable {
    public static let binSize = 8
    public let columns: Int
    public let rows: Int
    /// `starts[b]` to `starts[b + 1]` are the entries of bin `b` in `ranks`.
    let starts: ContiguousArray<Int32>
    let ranks: ContiguousArray<UInt32>
    /// Each drawn point's pixel as column << 16 | row, by draw rank, or `UInt32.max` for one off the image.
    let centres: ContiguousArray<UInt32>

    init(centres: ContiguousArray<UInt32>, width: Int, height: Int) {
        let columns = max((width + Self.binSize - 1) / Self.binSize, 1)
        let rows = max((height + Self.binSize - 1) / Self.binSize, 1)
        var starts = ContiguousArray<Int32>(repeating: 0, count: columns * rows + 1)
        func bin(_ centre: UInt32) -> Int { Int(centre >> 16) / Self.binSize + Int(centre & 0xFFFF) / Self.binSize * columns }
        for centre in centres where centre != UInt32.max { starts[bin(centre) + 1] += 1 }
        for index in 1..<starts.count { starts[index] += starts[index - 1] }
        var fill = starts
        var ranks = ContiguousArray<UInt32>(repeating: 0, count: Int(starts[starts.count - 1]))
        for (rank, centre) in centres.enumerated() where centre != UInt32.max {
            let b = bin(centre)
            ranks[Int(fill[b])] = UInt32(rank)
            fill[b] += 1
        }
        self.columns = columns
        self.rows = rows
        self.starts = starts
        self.ranks = ranks
        self.centres = centres
    }

    /// The draw rank of the point on top whose pixel lies within `reach` pixels of the pixel asked, or nil.
    public func hit(column: Int, row: Int, reach: Int) -> Int? {
        let binColumn = column / Self.binSize, binRow = row / Self.binSize
        let span = reach / Self.binSize + 1
        let rowLow = max(binRow - span, 0), rowHigh = min(binRow + span, rows - 1)
        let columnLow = max(binColumn - span, 0), columnHigh = min(binColumn + span, columns - 1)
        guard rowLow <= rowHigh, columnLow <= columnHigh else { return nil }
        var found: Int?
        for r in rowLow...rowHigh {
            for c in columnLow...columnHigh {
                let b = c + r * columns
                for entry in Int(starts[b])..<Int(starts[b + 1]) {
                    let rank = Int(ranks[entry])
                    let centre = centres[rank]
                    let dx = Int(centre >> 16) - column, dy = Int(centre & 0xFFFF) - row
                    if dx * dx + dy * dy <= reach * reach, rank > (found ?? -1) { found = rank }
                }
            }
        }
        return found
    }
}

/// One drawn plot: its pixels, the mapping it drew with and the grid that answers hover.
public struct RNASeqEmbeddingRaster: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: ContiguousArray<UInt32>
    public let mapping: RNASeqEmbeddingMapping
    public let order: ContiguousArray<UInt32>
    public let radius: Int
    public let grid: RNASeqEmbeddingGrid

    /// The cell, from 0, of the point on top at a pixel, or nil when no point lies within reach.
    public func cell(column: Int, row: Int) -> Int? {
        guard let rank = grid.hit(column: column, row: row, reach: radius + 1) else { return nil }
        return Int(order[rank])
    }

    /// Draws `input`. It checks for cancellation every 65,536 points, so a newer request stops an older one.
    public static func draw(_ input: RNASeqEmbeddingRasterInput) throws -> RNASeqEmbeddingRaster {
        let width = max(input.width, 1), height = max(input.height, 1), radius = max(input.radius, 0)
        precondition(width < 65_535 && height < 65_535, "a raster is at most 65,534 pixels a side")
        let mapping = RNASeqEmbeddingMapping(window: input.window, width: width, height: height, pad: input.pad)
        var dxs: [Int] = [], dys: [Int] = []
        for dy in -radius...radius {
            for dx in -radius...radius where dx * dx + dy * dy <= radius * radius {
                dxs.append(dx)
                dys.append(dy)
            }
        }
        let offsets = zip(dxs, dys).map { $0.1 * width + $0.0 }
        var pixels = ContiguousArray<UInt32>(repeating: 0, count: width * height)
        var centres = ContiguousArray<UInt32>(repeating: UInt32.max, count: input.order.count)
        let limitX = Float32(width), limitY = Float32(height)
        let minX = mapping.window.minX, maxY = mapping.window.maxY
        let scale = mapping.scale, originX = mapping.originX, originY = mapping.originY
        try pixels.withUnsafeMutableBufferPointer { out in
            try centres.withUnsafeMutableBufferPointer { kept in
                try input.order.withUnsafeBufferPointer { order in
                    try input.x.withUnsafeBufferPointer { xs in
                        try input.y.withUnsafeBufferPointer { ys in
                            try input.colour.withUnsafeBufferPointer { colours in
                                try input.palette.withUnsafeBufferPointer { palette in
                                    try offsets.withUnsafeBufferPointer { stamp in
                                        for rank in 0..<order.count {
                                            if rank & 0xFFFF == 0 { try Task.checkCancellation() }
                                            let cell = Int(order[rank])
                                            let fx = (xs[cell] - minX) * scale + originX
                                            let fy = (maxY - ys[cell]) * scale + originY
                                            // A NaN fails both tests, so a cell left out draws nothing.
                                            guard fx >= 0, fx < limitX, fy >= 0, fy < limitY else { continue }
                                            let column = Int(fx), row = Int(fy)
                                            kept[rank] = UInt32(column) << 16 | UInt32(row)
                                            let word = palette[Int(colours[cell])]
                                            if column >= radius, column < width - radius, row >= radius, row < height - radius {
                                                let centre = row * width + column
                                                for index in 0..<stamp.count { out[centre + stamp[index]] = word }
                                            } else {
                                                for index in 0..<dxs.count {
                                                    let c = column + dxs[index], r = row + dys[index]
                                                    if c >= 0, c < width, r >= 0, r < height { out[r * width + c] = word }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        try Task.checkCancellation()
        let grid = RNASeqEmbeddingGrid(centres: centres, width: width, height: height)
        return RNASeqEmbeddingRaster(width: width, height: height, pixels: pixels, mapping: mapping, order: input.order,
                                     radius: radius, grid: grid)
    }
}
