// GenotypeMatrixCellFontCacheRegressionTests.swift - Pixel/behavior guard for the cell-font cache
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// 2026-09-23 best-practices audit follow-up (PerfBenchGenotypeMatrixTests). Profiling that
// harness found `tableView(_:viewFor:row:)` -> `applyCellStyle` -> `font(for:)` resolving an
// `NSFont` from `ContentTypography` (an AppKit preferred-font lookup plus, for italic cells,
// `NSFontManager.shared.convert`) on every visible cell, on every scroll frame: ~595ms to build
// 40 rows x 96 columns. `font(for:)` now caches the four possible cell fonts (regular/semibold x
// upright/italic) in `cachedMatrixCellFonts`, cleared only in `applyContentTypography()` (the
// single place typography-affecting state is reapplied).
//
// This is a behavior-preservation guard, not a perf assertion (the perf numbers live in
// PerfBenchGenotypeMatrixTests, gated on LUNGFISH_PERF_BENCH=1): it asserts (1) the rendered
// matrix bitmap is pixel-identical whether or not the font cache is already warm, and (2) the
// cache actually returns font instances with the same visual properties, and does not go stale
// across a typography change.
import AppKit
import XCTest
@testable import LungfishGenotypeUI
@testable import LungfishCore
import LungfishIO
import LungfishTestSupport

@MainActor
final class GenotypeMatrixCellFontCacheRegressionTests: XCTestCase {

    func testWarmFontCacheProducesPixelIdenticalRedraw() throws {
        let matrix = try makeMatrix(sampleCount: 12, alleleCount: 20)

        // First render populates `cachedMatrixCellFonts` from a cold cache.
        let repA = try XCTUnwrap(matrix.bitmapImageRepForCachingDisplay(in: matrix.bounds))
        matrix.cacheDisplay(in: matrix.bounds, to: repA)

        // Second render reuses the now-warm cache. If caching changed which font object (or
        // font attributes) a cell receives, this render would differ from the first.
        let repB = try XCTUnwrap(matrix.bitmapImageRepForCachingDisplay(in: matrix.bounds))
        matrix.cacheDisplay(in: matrix.bounds, to: repB)

        assertPixelIdentical(repA, repB)
    }

    func testFontCacheInvalidatesOnContentTypographyChange() throws {
        // Isolated persistence, following the pattern in GenotypeResultDisplaySectionTests:
        // exercises the real `.contentTextSizeDidChange` notification path without touching
        // production UserDefaults.
        let typographySuiteName = "LungfishGenotypeMatrixFontCacheTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
        }

        let matrix = try makeMatrix(sampleCount: 8, alleleCount: 10)

        let smallRep = try XCTUnwrap(matrix.bitmapImageRepForCachingDisplay(in: matrix.bounds))
        matrix.cacheDisplay(in: matrix.bounds, to: smallRep)

        // Simulate a font-size preference change the way the real Settings UI produces one:
        // set the preference and call `save()`, which is what actually posts
        // `.contentTextSizeDidChange` (only when the persisted value differs) — the notification
        // `ContentTypographyViewObservation` is listening for.
        AppSettings.shared.contentTextSizePreference = .custom(200)
        AppSettings.shared.save()

        // Re-render at the new preference. A stale font cache (not cleared by
        // `applyContentTypography`) would keep painting the old point size, silently ignoring
        // the user's font-size preference change.
        let largeRep = try XCTUnwrap(matrix.bitmapImageRepForCachingDisplay(in: matrix.bounds))
        matrix.cacheDisplay(in: matrix.bounds, to: largeRep)

        XCTAssertFalse(
            bitmapsPixelIdentical(smallRep, largeRep),
            "Increasing the content text size preference should visibly change cell text " +
            "rendering; a stale font cache would make this render identical to the smaller size."
        )
    }

    // MARK: - Fixture

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
                    reads: 50 + (alleleIndex % 200)
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
            bundleURL: URL(fileURLWithPath: "/tmp/font-cache-regression.lungfishgenotype"),
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

    private func bitmapsPixelIdentical(_ repA: NSBitmapImageRep, _ repB: NSBitmapImageRep) -> Bool {
        guard repA.pixelsWide == repB.pixelsWide, repA.pixelsHigh == repB.pixelsHigh else { return false }
        for y in 0..<repA.pixelsHigh {
            for x in 0..<repA.pixelsWide {
                guard let colorA = repA.colorAt(x: x, y: y),
                      let colorB = repB.colorAt(x: x, y: y) else { continue }
                if !colorsApproximatelyEqual(colorA, colorB) { return false }
            }
        }
        return true
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
