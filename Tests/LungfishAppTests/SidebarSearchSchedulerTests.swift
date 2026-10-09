import XCTest
@testable import LungfishApp

@MainActor
final class SidebarSearchSchedulerTests: XCTestCase {
    func testRapidTypingCoalescesToOneLocalAndUniversalSearch() async throws {
        var localQueries: [String] = []
        var universalQueries: [String] = []
        let scheduler = SidebarSearchScheduler(
            debounceDelay: .milliseconds(25),
            minimumUniversalSearchLength: 3,
            onClear: {},
            onLocalSearch: { query, _ in localQueries.append(query) },
            onUniversalSearch: { query, _ in universalQueries.append(query) }
        )

        scheduler.submit("a")
        scheduler.submit("al")
        scheduler.submit("alpha")

        XCTAssertEqual(localQueries, [])
        XCTAssertEqual(universalQueries, [])

        await waitUntil {
            localQueries == ["alpha"] && universalQueries == ["alpha"]
        }
    }

    func testClearingSearchIsImmediateAndCancelsPendingWork() async throws {
        var didClear = false
        var localQueries: [String] = []
        let scheduler = SidebarSearchScheduler(
            debounceDelay: .milliseconds(40),
            minimumUniversalSearchLength: 3,
            onClear: { didClear = true },
            onLocalSearch: { query, _ in localQueries.append(query) },
            onUniversalSearch: { _, _ in }
        )

        scheduler.submit("alpha")
        scheduler.submit("")

        XCTAssertTrue(didClear)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(localQueries, [])
    }

    func testShortQueriesSkipUniversalSearch() async throws {
        var localQueries: [String] = []
        var universalQueries: [String] = []
        let scheduler = SidebarSearchScheduler(
            debounceDelay: .milliseconds(20),
            minimumUniversalSearchLength: 3,
            onClear: {},
            onLocalSearch: { query, _ in localQueries.append(query) },
            onUniversalSearch: { query, _ in universalQueries.append(query) }
        )

        scheduler.submit("ab")

        await waitUntil {
            localQueries == ["ab"]
        }
        XCTAssertEqual(universalQueries, [])
    }
}
