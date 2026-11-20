// RNASeqEmbeddingRasterBenchTests.swift - Opt-in bench of the embedding raster at 1,000,000 points (Phase 5.5 lane CM-VIEW)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The bar of 5.5 V1 and T4: 1,000,000 synthetic points rasterised at 1600x1000 points @2x (3200x2000 pixels) with a
// median under 100 ms on galah. It runs only when LUNGFISH_PERF_BENCH=1 is set, so no gate runs it, and it is timed only
// while no lane builds. It prints the first pass, the median, the slowest pass and the grid's share.

import Foundation
import XCTest
@testable import LungfishRNASeqUI

final class RNASeqEmbeddingRasterBenchTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LUNGFISH_PERF_BENCH"] == "1",
                          "Set LUNGFISH_PERF_BENCH=1 to run the embedding raster bench.")
    }

    func testOneMillionPointsAt1600x1000At2x() throws {
        let count = 1_000_000
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Float32 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float32(state >> 40) / Float32(1 << 24)
        }
        var x = ContiguousArray<Float32>(repeating: 0, count: count)
        var y = ContiguousArray<Float32>(repeating: 0, count: count)
        var colour = ContiguousArray<UInt16>(repeating: 0, count: count)
        for cell in 0..<count {
            // Twelve clusters of uneven spread, as an embedding of many cells looks.
            let cluster = cell % 12
            x[cell] = Float32(cluster % 4) * 10 + (next() + next() + next() - 1.5) * Float32(1 + cluster % 3)
            y[cell] = Float32(cluster / 4) * 10 + (next() + next() + next() - 1.5) * Float32(1 + cluster % 2)
            colour[cell] = UInt16(cluster)
        }
        let order = ContiguousArray((0..<UInt32(count)))
        let input = RNASeqEmbeddingRasterInput(x: x, y: y, order: order, colour: colour, palette: RNASeqEmbeddingPalette.words(dark: false),
                                               width: 3200, height: 2000, radius: 2, window: .fit(x: x, y: y, order: order))
        var times: [Double] = []
        var last: RNASeqEmbeddingRaster?
        for _ in 0..<21 {
            let start = DispatchTime.now().uptimeNanoseconds
            last = try RNASeqEmbeddingRaster.draw(input)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        let sorted = times.sorted()
        let median = sorted[sorted.count / 2]
        let drawn = try XCTUnwrap(last).pixels.reduce(0) { $1 == 0 ? $0 : $0 + 1 }
        print(String(format: "CM-VIEW raster bench: 1000000 points 3200x2000 px radius 2, first %.1f ms, median %.1f ms, slowest %.1f ms, %d pixels set, passes %d",
                     times[0], median, sorted.last ?? 0, drawn, times.count))
        XCTAssertLessThan(median, 100, "the median raster of 1,000,000 points stays under 100 ms (5.5 V1)")
    }
}
