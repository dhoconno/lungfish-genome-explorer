import XCTest
@testable import LungfishCLI

final class CondaPacksCommandTests: XCTestCase {

    func testVisibleCLIPacksOnlyIncludeRequiredAndActivePacks() {
        XCTAssertEqual(
            CondaCommand.visiblePacksForTesting().map(\.id),
            ["lungfish-tools", "read-mapping", "variant-calling", "assembly", "metagenomics"]
        )
    }
}
