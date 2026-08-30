import XCTest
@testable import LungfishApp

@MainActor
final class OperationLogStateIsolationTests: XCTestCase {
    func testDebugOperationLogsUseAnIsolatedDirectory() {
        let library = URL(fileURLWithPath: "/tmp/Library", isDirectory: true)

        XCTAssertEqual(
            OperationLogDocument.defaultLogsDirectory(
                appIdentity: .stable,
                libraryDirectory: library
            ),
            library.appendingPathComponent("Logs/Lungfish/Operations", isDirectory: true)
        )
        XCTAssertEqual(
            OperationLogDocument.defaultLogsDirectory(
                appIdentity: .debug,
                libraryDirectory: library
            ),
            library.appendingPathComponent("Logs/Lungfish Debug/Operations", isDirectory: true)
        )
    }
}
