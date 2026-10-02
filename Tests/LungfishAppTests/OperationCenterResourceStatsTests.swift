import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class OperationCenterResourceStatsTests: XCTestCase {
    func testCompletedOperationRowsRecordWallTimeAndPeakMemoryWhenAvailable() {
        let center = OperationCenter()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let id = center.begin(
            title: "Kraken2",
            detail: "Running",
            operationType: .download,
            startedAt: startedAt,
            cliCommand: nil
        ).rowID

        center.updateResourceStats(id: id, peakMemoryBytes: 4_294_967_296)
        center.complete(
            id: id,
            detail: "Complete",
            finishedAt: Date(timeIntervalSince1970: 1_012)
        )

        let item = center.items.first(where: { $0.id == id })
        XCTAssertEqual(item?.wallTimeSeconds, 12)
        XCTAssertEqual(item?.peakMemoryBytes, 4_294_967_296)
    }
}
