import XCTest
@testable import LungfishCLI

final class OpsCommandTests: XCTestCase {
    func testOpsStatsCommandIsRegisteredAtRoot() {
        XCTAssertTrue(LungfishCLI.configuration.subcommands.contains { $0 == OpsCommand.self })
        XCTAssertEqual(OpsCommand.configuration.commandName, "ops")
        XCTAssertTrue(OpsCommand.helpMessage().contains("stats"))
    }
}
