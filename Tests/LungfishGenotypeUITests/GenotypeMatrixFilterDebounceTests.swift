import XCTest
@testable import LungfishGenotypeUI
import LungfishIO
import LungfishTestSupport

/// F21: `GenotypeComparisonMatrixView`'s free-text filter field must debounce
/// user keystrokes before recomputing (filter, sort, rebuild visible-row
/// index, diff-based table reload) exactly like `BatchTableView.scheduleFilterApply`
/// and `ViralDetectionTableView.setFilterText(_:debounce:)` already do.
final class GenotypeMatrixFilterDebounceTests: XCTestCase {
    @MainActor
    func testRapidSuccessiveFilterKeystrokesCoalesceToOneRecompute() throws {
        let matrix = GenotypeComparisonMatrixView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 500)
        )
        let window = NSWindow(
            contentRect: matrix.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = matrix
        matrix.configure(result: makeResult(calls: [
            makeCall(sample: "AnimalA", genotype: "Mafa-A1*001:01", reads: 12),
            makeCall(sample: "AnimalA", genotype: "Mafa-A1*002:01", reads: 8),
            makeCall(sample: "AnimalA", genotype: "Mafa-B1*003:01", reads: 5),
        ]))
        matrix.testingResetProjectionPerformanceCounters()

        // Fire three rapid keystrokes the way a fast typist would, without
        // waiting for the debounce window to elapse between them.
        XCTAssertTrue(matrix.testingPerformNativeFilterAction(
            text: "M",
            selectedRange: NSRange(location: 1, length: 0),
            in: window
        ))
        XCTAssertTrue(matrix.testingPerformNativeFilterAction(
            text: "Ma",
            selectedRange: NSRange(location: 2, length: 0),
            in: window
        ))
        XCTAssertTrue(matrix.testingPerformNativeFilterAction(
            text: "Mafa-A",
            selectedRange: NSRange(location: 6, length: 0),
            in: window
        ))

        // The recompute must not have run synchronously for any of the three
        // keystrokes yet -- only after the debounce interval elapses.
        XCTAssertEqual(matrix.testingApplyFilterAndSortInvocationCount, 0)

        try waitUntil(timeout: 2.0) {
            matrix.testingApplyFilterAndSortInvocationCount == 1
        }

        XCTAssertEqual(matrix.testingApplyFilterAndSortInvocationCount, 1)
        XCTAssertEqual(
            Set(matrix.testingVisibleRows.map(\.genotype)),
            ["Mafa-A1*001:01", "Mafa-A1*002:01"]
        )
        // The text field itself must stay responsive/up to date even though
        // the recompute was deferred.
        XCTAssertEqual(matrix.testingFilterModelText, "Mafa-A")
    }

    @MainActor
    func testClearingFilterAppliesImmediatelyWithoutWaitingForDebounce() throws {
        let matrix = GenotypeComparisonMatrixView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 500)
        )
        let window = NSWindow(
            contentRect: matrix.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = matrix
        matrix.configure(result: makeResult(calls: [
            makeCall(sample: "AnimalA", genotype: "Mafa-A1*001:01", reads: 12),
            makeCall(sample: "AnimalA", genotype: "Mafa-B1*003:01", reads: 5),
        ]))
        XCTAssertTrue(matrix.testingPerformNativeFilterAction(
            text: "Mafa-A",
            selectedRange: NSRange(location: 6, length: 0),
            in: window
        ))
        try waitUntil(timeout: 2.0) {
            matrix.testingVisibleRows.count == 1
        }

        matrix.testingResetProjectionPerformanceCounters()
        XCTAssertTrue(matrix.testingPerformNativeFilterAction(
            text: "",
            selectedRange: NSRange(location: 0, length: 0),
            in: window
        ))

        // Clearing the filter must not wait for the debounce window.
        try waitUntil(timeout: 2.0) {
            matrix.testingApplyFilterAndSortInvocationCount == 1
        }
        XCTAssertEqual(matrix.testingApplyFilterAndSortInvocationCount, 1)
        XCTAssertEqual(matrix.testingVisibleRows.count, 2)
    }

    private func makeCall(sample: String, genotype: String, reads: Int) -> ONTGenotypeCall {
        GenotypeTestFixtures.makeCall(sample: sample, genotype: genotype, reads: reads)
    }

    private func makeResult(
        bundleURL: URL = URL(fileURLWithPath: "/tmp/debounce-example.lungfishgenotype"),
        calls: [ONTGenotypeCall]
    ) -> ONTGenotypeResultBundleData {
        GenotypeTestFixtures.makeResult(
            bundleURL: bundleURL,
            calls: calls,
            kind: GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue
        )
    }
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 10.0,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(condition(), file: file, line: line)
}
