import XCTest
import LungfishIO
@testable import LungfishApp

/// Guards the per-position quality boxplot against drawing past its chart
/// rect. Before the layout existed, 250 positions in a 490pt chart produced
/// 250 three-point slots (750pt) and the chart was clipped at position ~163.
final class FASTQBoxplotLayoutTests: XCTestCase {

    /// The popover is 560pt wide with 50pt left and 20pt right margins.
    private let popoverChartRect = CGRect(x: 50, y: 30, width: 490, height: 270)

    private func summaries(count: Int) -> [PositionQualitySummary] {
        (0..<count).map { position in
            let q = Double(40 - position % 10)
            return PositionQualitySummary(
                position: position, mean: q, median: q,
                lowerQuartile: q - 2, upperQuartile: q + 1,
                percentile10: q - 5, percentile90: q + 2
            )
        }
    }

    private func assertFitsChart(_ layout: FASTQBoxplotLayout, file: StaticString = #filePath, line: UInt = #line) {
        let rect = layout.chartRect
        XCTAssertFalse(layout.bins.isEmpty, "expected at least one bin", file: file, line: line)
        for index in layout.bins.indices {
            let minX = layout.boxMinX(at: index)
            let maxX = minX + layout.boxWidth
            XCTAssertGreaterThanOrEqual(minX, rect.minX - 0.001, "bin \(index) starts left of the chart", file: file, line: line)
            XCTAssertLessThanOrEqual(maxX, rect.maxX + 0.001, "bin \(index) ends right of the chart", file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(layout.boxWidth, 1, file: file, line: line)
    }

    func testEveryPositionIsCoveredExactlyOnce() {
        for count in [1, 35, 250, 1000] {
            let layout = FASTQBoxplotLayout.layout(summaries: summaries(count: count), chartRect: popoverChartRect)
            let covered = layout.bins.flatMap { Array($0.positions) }
            XCTAssertEqual(covered, Array(0..<count), "count \(count)")
        }
    }

    func test250PositionsFitTheExpandedPopoverChart() {
        let layout = FASTQBoxplotLayout.layout(summaries: summaries(count: 250), chartRect: popoverChartRect)
        assertFitsChart(layout)
        XCTAssertEqual(layout.positionsPerBin, 2)
        XCTAssertEqual(layout.bins.count, 125)
        XCTAssertEqual(layout.bins.last?.positions, 248...249)
        XCTAssertEqual(layout.bins.last?.label, "249-250")
    }

    func test35PositionsGetOneBoxPerPosition() {
        let layout = FASTQBoxplotLayout.layout(summaries: summaries(count: 35), chartRect: popoverChartRect)
        assertFitsChart(layout)
        XCTAssertEqual(layout.positionsPerBin, 1)
        XCTAssertEqual(layout.bins.count, 35)
        XCTAssertEqual(layout.bins[0].label, "1")
        XCTAssertEqual(layout.bins[34].label, "35")
        XCTAssertEqual(layout.slotWidth, 490.0 / 35.0, accuracy: 0.001)
    }

    func test1000PositionsFitTheExpandedPopoverChart() {
        let layout = FASTQBoxplotLayout.layout(summaries: summaries(count: 1000), chartRect: popoverChartRect)
        assertFitsChart(layout)
        XCTAssertGreaterThan(layout.positionsPerBin, 1)
        XCTAssertLessThanOrEqual(layout.bins.count, Int(490 / FASTQBoxplotLayout.minimumSlotWidth))
        XCTAssertEqual(layout.bins.last?.positions.upperBound, 999)
    }

    func testNarrowChartStillFits() {
        let narrow = CGRect(x: 10, y: 0, width: 40, height: 100)
        let layout = FASTQBoxplotLayout.layout(summaries: summaries(count: 250), chartRect: narrow)
        assertFitsChart(layout)
        XCTAssertLessThanOrEqual(layout.bins.count, 13)
    }

    func testPooledBinAveragesItsStatistics() {
        let input = [
            PositionQualitySummary(position: 0, mean: 30, median: 32, lowerQuartile: 28, upperQuartile: 36, percentile10: 20, percentile90: 40),
            PositionQualitySummary(position: 1, mean: 20, median: 22, lowerQuartile: 18, upperQuartile: 26, percentile10: 10, percentile90: 30),
        ]
        // A 3pt chart holds exactly one bin, so both positions pool together.
        let layout = FASTQBoxplotLayout.layout(summaries: input, chartRect: CGRect(x: 0, y: 0, width: 3, height: 10))
        XCTAssertEqual(layout.bins.count, 1)
        let pooled = layout.bins[0].summary
        XCTAssertEqual(pooled.position, 0)
        XCTAssertEqual(pooled.mean, 25)
        XCTAssertEqual(pooled.median, 27)
        XCTAssertEqual(pooled.lowerQuartile, 23)
        XCTAssertEqual(pooled.upperQuartile, 31)
        XCTAssertEqual(pooled.percentile10, 15)
        XCTAssertEqual(pooled.percentile90, 35)
        XCTAssertEqual(layout.bins[0].label, "1-2")
    }

    func testLabelledBinsNeverCrowdAndAlwaysIncludeTheFirst() {
        let layout = FASTQBoxplotLayout.layout(summaries: summaries(count: 250), chartRect: popoverChartRect)
        let indices = layout.labelledBinIndices(labelWidth: 50)
        XCTAssertEqual(indices.first, 0)
        XCTAssertLessThanOrEqual(indices.count, Int(490 / 50))
        for pair in zip(indices, indices.dropFirst()) {
            XCTAssertGreaterThanOrEqual(layout.boxMidX(at: pair.1) - layout.boxMidX(at: pair.0), 50 - layout.slotWidth)
        }
    }

    func testEmptyInputProducesNoBins() {
        let layout = FASTQBoxplotLayout.layout(summaries: [], chartRect: popoverChartRect)
        XCTAssertTrue(layout.bins.isEmpty)
        XCTAssertTrue(layout.labelledBinIndices(labelWidth: 35).isEmpty)
    }
}
