import XCTest
@testable import LungfishApp

final class FASTQImportSlotCoordinatorTests: XCTestCase {
    func testQueuedAcquireThrowsWhenCancelledBeforeSlotIsAvailable() async throws {
        let coordinator = FASTQImportSlotCoordinator(maxConcurrentImports: 1)
        try await coordinator.acquire()

        let queued = Task { () -> String in
            do {
                try await coordinator.acquire()
                await coordinator.release()
                return "acquired"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "failed: \(error)"
            }
        }

        try await waitForWaitingImport(on: coordinator)
        queued.cancel()
        try await Task.sleep(nanoseconds: 20_000_000)

        await coordinator.release()
        let outcome = await queued.value
        XCTAssertEqual(outcome, "cancelled")

        let snapshot = await coordinator.testingSnapshot()
        XCTAssertEqual(snapshot.activeImports, 0)
        XCTAssertEqual(snapshot.waitingImports, 0)
    }

    private func waitForWaitingImport(
        on coordinator: FASTQImportSlotCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<100 {
            if await coordinator.testingSnapshot().waitingImports == 1 {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for queued FASTQ import", file: file, line: line)
    }
}
