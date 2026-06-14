import XCTest
@testable import LungfishApp

@MainActor
final class SidebarRefreshSchedulerTests: XCTestCase {
    func testRapidReloadRequestsCoalesceToOneRefresh() async throws {
        var refreshes: [Bool] = []
        let scheduler = SidebarRefreshScheduler(debounce: .milliseconds(20)) { notify in
            refreshes.append(notify)
        }

        scheduler.requestFullReload(notifyUnchangedSelectionRefresh: true)
        scheduler.requestFullReload(notifyUnchangedSelectionRefresh: false)
        scheduler.requestFullReload(notifyUnchangedSelectionRefresh: false)

        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(refreshes, [true])
    }

    func testCancelDropsPendingReload() async throws {
        var refreshCount = 0
        let scheduler = SidebarRefreshScheduler(debounce: .milliseconds(40)) { _ in
            refreshCount += 1
        }

        scheduler.requestFullReload()
        scheduler.cancel()

        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(refreshCount, 0)
    }
}
