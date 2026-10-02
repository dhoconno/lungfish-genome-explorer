import XCTest
@testable import LungfishGenotypeUI
import LungfishIO
import LungfishTestSupport

/// F21: `GenotypeComparisonMatrixView`'s free-text filter field must debounce
/// user keystrokes before recomputing (filter, sort, rebuild visible-row
/// index, diff-based table reload) exactly like `BatchTableView.scheduleFilterApply`
/// and `ViralDetectionTableView.setFilterText(_:debounce:)` already do.
///
/// Each test drives the debounce through `ManualMatrixFilterDebounce`, so the
/// test decides when the delay has passed. Waiting up to 2 s of wall time for the
/// real 180 ms sleep failed under the loaded parallel unit gate (gate 10,
/// 2026-10-02) before the first recompute ran.
final class GenotypeMatrixFilterDebounceTests: XCTestCase {
    @MainActor
    func testImmediateExportSettlesNativeSearchAndCancelsDelayedRecompute() throws {
        let matrix = GenotypeComparisonMatrixView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        let window = NSWindow(contentRect: matrix.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = matrix
        matrix.configure(result: makeResult(calls: [
            makeCall(sample: "AnimalA", genotype: "Mafa-A1*001:01", reads: 12),
            makeCall(sample: "AnimalA", genotype: "Mafa-B1*003:01", reads: 5),
        ]))
        let debounce = installManualDebounce(on: matrix)
        matrix.testingResetProjectionPerformanceCounters()
        XCTAssertTrue(matrix.testingPerformNativeFilterAction(text: "Mafa-A", selectedRange: NSRange(location: 6, length: 0), in: window))
        let snapshot = matrix.exportSnapshot(bundleURL: URL(fileURLWithPath: "/tmp/search.lungfishgenotype"), analysisName: "Search", lens: "matrix")
        XCTAssertEqual(snapshot.rows.map(\.genotype), ["Mafa-A1*001:01"])
        XCTAssertEqual(snapshot.filters["searchText"], "Mafa-A")
        XCTAssertEqual(matrix.testingApplyFilterAndSortInvocationCount, 1)
        // The export cancelled the keystroke's delayed recompute, so letting its
        // delay pass must not recompute a second time.
        XCTAssertEqual(debounce.armed.map(\.task.isCancelled), [true])
        debounce.elapseAll()
        XCTAssertEqual(matrix.testingApplyFilterAndSortInvocationCount, 1)
        XCTAssertEqual(matrix.testingFilterModelText, "Mafa-A")
    }

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
        let debounce = installManualDebounce(on: matrix)
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
        XCTAssertEqual(
            debounce.armed.map(\.delay),
            Array(repeating: .milliseconds(180), count: 3),
            "Each keystroke must arm a recompute 180 ms out, the BatchTableView delay"
        )
        XCTAssertEqual(
            debounce.armed.map(\.task.isCancelled), [true, true, false],
            "Each keystroke must cancel the recompute the previous keystroke armed"
        )

        debounce.elapseAll()

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
        let debounce = installManualDebounce(on: matrix)
        XCTAssertTrue(matrix.testingPerformNativeFilterAction(
            text: "Mafa-A",
            selectedRange: NSRange(location: 6, length: 0),
            in: window
        ))
        debounce.elapseAll()
        XCTAssertEqual(matrix.testingVisibleRows.count, 1)

        matrix.testingResetProjectionPerformanceCounters()
        XCTAssertTrue(matrix.testingPerformNativeFilterAction(
            text: "",
            selectedRange: NSRange(location: 0, length: 0),
            in: window
        ))

        // Clearing the filter must not wait for the debounce window.
        XCTAssertTrue(debounce.armed.isEmpty, "Clearing the filter must not arm a delayed recompute")
        XCTAssertEqual(matrix.testingApplyFilterAndSortInvocationCount, 1)
        XCTAssertEqual(matrix.testingVisibleRows.count, 2)
    }

    @MainActor
    private func installManualDebounce(on matrix: GenotypeComparisonMatrixView) -> ManualMatrixFilterDebounce {
        let debounce = ManualMatrixFilterDebounce()
        matrix.filterDebounceScheduler = { debounce.arm(after: $0, $1) }
        return debounce
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

/// Stands in for `GenotypeComparisonMatrixView.filterDebounceScheduler`. It keeps
/// each armed recompute with the task it handed the view, so a test decides when
/// the debounce delay has passed instead of waiting on the clock.
@MainActor
private final class ManualMatrixFilterDebounce {
    private(set) var armed: [(delay: Duration, task: Task<Void, Never>, recompute: @MainActor () -> Void)] = []

    func arm(after delay: Duration, _ recompute: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        // The view only ever cancels the task it gets back, and a task records
        // its cancellation even after it has finished, so an empty task carries
        // the state the default scheduler's sleeping task would.
        let task = Task<Void, Never> {}
        armed.append((delay, task, recompute))
        return task
    }

    /// Runs every armed recompute whose task was not cancelled, as the default
    /// scheduler does once its delay has passed.
    func elapseAll() {
        let due = armed
        armed.removeAll()
        for entry in due where !entry.task.isCancelled {
            entry.recompute()
        }
    }
}
