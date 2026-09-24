// PerfBenchGenotypeMatrixTests.swift - Opt-in draw/cell-build benchmark
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// 2026-09-23 best-practices audit (concurrency-performance.md, WP8). GenotypeComparisonMatrixView
// is backed by NSTableView, so AppKit already virtualizes which rows/cells are drawn or built —
// unlike SequenceViewerView/MSA, there is no custom draw(_:) that repaints the whole data set
// per frame. The audit's ask ("remove draw-time sorting/formatting/text measurement... draw
// only visible cells") maps to `tableView(_:viewFor:row:)`, which AppKit calls once per visible
// cell on every scroll frame; `cellValue(for:row:)` inside it does per-cell tooltip string
// building (`matrixTooltip`, `cachedRowCommentTooltips`) and dictionary lookups. This harness
// renders the real matrix into an NSBitmapImageRep (exercising the actual display pipeline,
// including layoutSubtreeIfNeeded and AppKit's own cell virtualization) and reports median full
// redraw time over >=20 passes, for a realistic 96-sample x 200-allele result. It only runs when
// LUNGFISH_PERF_BENCH=1 is set.
import AppKit
import XCTest
@testable import LungfishGenotypeUI
import LungfishIO
import LungfishTestSupport

@MainActor
final class PerfBenchGenotypeMatrixTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LUNGFISH_PERF_BENCH"] == "1",
            "Set LUNGFISH_PERF_BENCH=1 to run offscreen rendering benchmarks."
        )
    }

    func testFullMatrixRedrawBenchmark() throws {
        let matrix = try makeLargeMatrix(sampleCount: 96, alleleCount: 200)
        let rep = try XCTUnwrap(matrix.bitmapImageRepForCachingDisplay(in: matrix.bounds))

        var samples: [Double] = []
        samples.reserveCapacity(20)
        for _ in 0..<20 {
            let start = CFAbsoluteTimeGetCurrent()
            matrix.cacheDisplay(in: matrix.bounds, to: rep)
            samples.append(CFAbsoluteTimeGetCurrent() - start)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        print("[LUNGFISH_PERF_BENCH] GenotypeComparisonMatrixView full redraw (96 samples x 200 alleles): median \(String(format: "%.3f", median * 1000)) ms")
    }

    /// Isolates the cell-build cost (`tableView(_:viewFor:row:)` + `cellValue`) from AppKit's own
    /// compositing, by calling the delegate method directly for every visible row/column
    /// combination — this is the part PERF work can actually change (draw-time formatting), as
    /// opposed to AppKit's own cell drawing, which this view does not customize.
    func testCellBuildCostBenchmark() throws {
        let matrix = try makeLargeMatrix(sampleCount: 96, alleleCount: 200)
        let descendants = Self.descendants(of: matrix)
        let table = try XCTUnwrap(descendants.compactMap { $0 as? NSTableView }.first {
            $0.accessibilityIdentifier() == "genotype-comparison-table"
        })
        let columns = table.tableColumns
        let rowCount = table.numberOfRows

        var samples: [Double] = []
        samples.reserveCapacity(20)
        for _ in 0..<20 {
            let start = CFAbsoluteTimeGetCurrent()
            for row in 0..<min(rowCount, 40) {
                for column in columns {
                    _ = matrix.tableView(table, viewFor: column, row: row)
                }
            }
            samples.append(CFAbsoluteTimeGetCurrent() - start)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        print("[LUNGFISH_PERF_BENCH] GenotypeComparisonMatrixView cell-build (40 visible rows x \(columns.count) columns): median \(String(format: "%.3f", median * 1000)) ms")
    }

    // MARK: - Fixture

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func makeLargeMatrix(sampleCount: Int, alleleCount: Int) throws -> GenotypeComparisonMatrixView {
        var calls: [ONTGenotypeCall] = []
        calls.reserveCapacity(sampleCount * alleleCount / 4)
        var samples: [ONTGenotypeSampleResult] = []
        samples.reserveCapacity(sampleCount)

        for sampleIndex in 0..<sampleCount {
            let sampleName = String(format: "SAMPLE_%03d", sampleIndex)
            var sampleCalls: [ONTGenotypeCall] = []
            // Each sample supports roughly a quarter of the alleles, mirroring a realistic
            // sparse genotype matrix rather than a dense one.
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
            bundleURL: URL(fileURLWithPath: "/tmp/perf-bench.lungfishgenotype"),
            samples: samples,
            calls: calls,
            kind: "ont-barcode-genotype"
        )

        let matrix = GenotypeComparisonMatrixView(frame: NSRect(x: 0, y: 0, width: 1600, height: 900))
        matrix.configure(result: result, sidecar: nil)
        matrix.layoutSubtreeIfNeeded()
        return matrix
    }
}
