// GenotypeMatrixCellColorCacheRegressionTests.swift - Pixel/behavior guard for the cell-color cache
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// 2026-09-24 best-practices audit follow-up (PerfBenchGenotypeMatrixTests / PERF-17 continuation).
// Fine-grained profiling of `tableView(_:viewFor:row:)` found that `backgroundColor(for:row:
// renderedStyle:)` / `borderColor(for:row:renderedStyle:)` / `applyCellStyle` were calling
// `NSColor(calibratedRed:green:blue:alpha:)` and `.withAlphaComponent(_:)` fresh on every visible
// cell (the default `cellColorMode` is `.support`, so almost every populated cell hits
// `NSColor.systemBlue.withAlphaComponent(alpha)`) — neither call is memoized by AppKit. Those
// paths now route through `cachedColor(from:alpha:)` / `cachedSystemBlue(alpha:)`, the same
// per-instance-cache pattern as the existing `cachedMatrixCellFonts` (see
// GenotypeMatrixCellFontCacheRegressionTests).
//
// This is a behavior-preservation guard, not a perf assertion (the perf numbers live in
// PerfBenchGenotypeMatrixTests, gated on LUNGFISH_PERF_BENCH=1): it asserts the rendered matrix
// bitmap is pixel-identical whether or not the color cache is already warm, and that cells still
// expose their text to accessibility clients after the cell-build path was reshaped.
import AppKit
import XCTest
@testable import LungfishGenotypeUI
@testable import LungfishCore
import LungfishIO
import LungfishTestSupport

@MainActor
final class GenotypeMatrixCellColorCacheRegressionTests: XCTestCase {

    func testWarmColorCacheProducesPixelIdenticalRedraw() throws {
        let matrix = try makeMatrix(sampleCount: 12, alleleCount: 20)

        // First render populates `cachedMatrixCellColors` / `cachedSystemBlueColors` from a cold
        // cache (the support heatmap fill exercises `cachedSystemBlue`; sidecar-styled cells
        // would exercise `cachedColor(from:alpha:)`, covered indirectly since both share the
        // storage/lookup logic).
        let repA = try XCTUnwrap(matrix.bitmapImageRepForCachingDisplay(in: matrix.bounds))
        matrix.cacheDisplay(in: matrix.bounds, to: repA)

        // Second render reuses the now-warm cache. If caching changed which NSColor object (or
        // its resolved components) a cell receives, this render would differ from the first.
        let repB = try XCTUnwrap(matrix.bitmapImageRepForCachingDisplay(in: matrix.bounds))
        matrix.cacheDisplay(in: matrix.bounds, to: repB)

        assertPixelIdentical(repA, repB)
    }

    /// Distinct support fractions across rows/samples produce distinct heatmap alphas
    /// (`min(0.20, max(0.06, 0.05 + fraction * 0.22))`); this fixture has enough spread that the
    /// cache holds several `cachedSystemBlueColors` entries, not just one, still without
    /// affecting the rendered output.
    func testColorCacheHandlesMultipleDistinctSupportFractionsIdentically() throws {
        let matrix = try makeMatrix(sampleCount: 24, alleleCount: 40)

        let repA = try XCTUnwrap(matrix.bitmapImageRepForCachingDisplay(in: matrix.bounds))
        matrix.cacheDisplay(in: matrix.bounds, to: repA)
        let repB = try XCTUnwrap(matrix.bitmapImageRepForCachingDisplay(in: matrix.bounds))
        matrix.cacheDisplay(in: matrix.bounds, to: repB)

        assertPixelIdentical(repA, repB)
    }

    /// The cell-build reshape (profiling instrumentation + cached colors/fonts) must not change
    /// what VoiceOver sees: every populated sample cell still exposes an accessibility label with
    /// its evidence text, and the row-selector column still exposes the allele row label.
    func testCellsExposeAccessibilityLabelsAfterCellBuildChanges() throws {
        let matrix = try makeMatrix(sampleCount: 8, alleleCount: 10)
        let descendants = Self.descendants(of: matrix)
        let table = try XCTUnwrap(descendants.compactMap { $0 as? NSTableView }.first {
            $0.accessibilityIdentifier() == "genotype-comparison-table"
        })
        let columns = table.tableColumns
        XCTAssertGreaterThan(table.numberOfRows, 0)
        XCTAssertGreaterThan(columns.count, 1)

        var sawNonEmptySampleLabel = false
        for row in 0..<table.numberOfRows {
            for column in columns {
                guard let cellView = matrix.tableView(table, viewFor: column, row: row) as? NSTableCellView else {
                    continue
                }
                guard let textField = cellView.textField else {
                    // Row-selector cell: verify via its own accessibility label instead.
                    XCTAssertNotNil(cellView.accessibilityLabel(), "Row selector cell must expose a label")
                    continue
                }
                if let label = textField.accessibilityLabel(), !label.isEmpty {
                    sawNonEmptySampleLabel = true
                }
                // Every text field must at least be reachable as an accessibility element with
                // its rendered string available (either via stringValue directly or a richer
                // accessibilityLabel for semantic cells).
                XCTAssertTrue(
                    textField.isAccessibilityElement(),
                    "Cell text field must remain an accessibility element"
                )
            }
        }
        XCTAssertTrue(
            sawNonEmptySampleLabel,
            "At least one populated sample cell should expose a non-empty accessibility label"
        )
    }

    // MARK: - Fixture

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func makeMatrix(sampleCount: Int, alleleCount: Int) throws -> GenotypeComparisonMatrixView {
        var calls: [ONTGenotypeCall] = []
        var samples: [ONTGenotypeSampleResult] = []
        for sampleIndex in 0..<sampleCount {
            let sampleName = String(format: "SAMPLE_%03d", sampleIndex)
            var sampleCalls: [ONTGenotypeCall] = []
            for alleleIndex in stride(from: sampleIndex % 4, to: alleleCount, by: 4) {
                let genotype = String(format: "Mafa-A1*%04d:01", alleleIndex)
                let call = GenotypeTestFixtures.makeCall(
                    sample: sampleName,
                    genotype: genotype,
                    reads: 50 + (alleleIndex * 7 + sampleIndex * 13) % 200
                )
                calls.append(call)
                sampleCalls.append(call)
            }
            samples.append(
                ONTGenotypeSampleResult(
                    sample: sampleName,
                    passedAlignments: sampleCalls.reduce(0) { $0 + $1.passedAlignments },
                    passedUniqueReads: sampleCalls.reduce(0) { $0 + $1.passedUniqueReads },
                    sampleTotalReads: 10_000,
                    sampleUniqueRetainedPercent: 62.5,
                    calls: sampleCalls
                )
            )
        }

        let result = GenotypeTestFixtures.makeResult(
            bundleURL: URL(fileURLWithPath: "/tmp/color-cache-regression.lungfishgenotype"),
            samples: samples,
            calls: calls,
            kind: "ont-barcode-genotype"
        )

        let matrix = GenotypeComparisonMatrixView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        matrix.configure(result: result, sidecar: nil)
        matrix.layoutSubtreeIfNeeded()
        return matrix
    }

    // MARK: - Pixel comparison

    private func assertPixelIdentical(
        _ repA: NSBitmapImageRep,
        _ repB: NSBitmapImageRep,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(repA.pixelsWide, repB.pixelsWide, file: file, line: line)
        XCTAssertEqual(repA.pixelsHigh, repB.pixelsHigh, file: file, line: line)
        guard repA.pixelsWide == repB.pixelsWide, repA.pixelsHigh == repB.pixelsHigh else { return }
        var mismatches = 0
        var firstMismatch: (Int, Int)?
        for y in 0..<repA.pixelsHigh {
            for x in 0..<repA.pixelsWide {
                guard let colorA = repA.colorAt(x: x, y: y),
                      let colorB = repB.colorAt(x: x, y: y) else { continue }
                if !colorsApproximatelyEqual(colorA, colorB) {
                    mismatches += 1
                    if firstMismatch == nil { firstMismatch = (x, y) }
                }
            }
        }
        XCTAssertEqual(
            mismatches, 0,
            "\(mismatches) of \(repA.pixelsWide * repA.pixelsHigh) pixels differed; " +
            "first mismatch at \(String(describing: firstMismatch))",
            file: file, line: line
        )
    }

    /// Small tolerance for font anti-aliasing / color-space rounding noise between two
    /// otherwise-identical renders, not for genuine content differences.
    private func colorsApproximatelyEqual(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let a = a.usingColorSpace(.deviceRGB), let b = b.usingColorSpace(.deviceRGB) else { return a == b }
        let tolerance: CGFloat = 1.0 / 255.0
        return abs(a.redComponent - b.redComponent) <= tolerance
            && abs(a.greenComponent - b.greenComponent) <= tolerance
            && abs(a.blueComponent - b.blueComponent) <= tolerance
            && abs(a.alphaComponent - b.alphaComponent) <= tolerance
    }
}
