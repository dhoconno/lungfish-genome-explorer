import XCTest
@testable import LungfishApp

@MainActor
final class ProjectSessionRegistryTests: XCTestCase {
    func testRegistersMultipleSessionsForSameCanonicalProjectURL() {
        let registry = ProjectSessionRegistry()
        let url = URL(fileURLWithPath: "/tmp/Shared.lungfish", isDirectory: true)
        let first = ProjectSession()
        let second = ProjectSession()

        registry.register(first, projectURL: url)
        registry.register(second, projectURL: url.standardizedFileURL)

        XCTAssertEqual(registry.sessions(forProjectURL: url).count, 2)
        XCTAssertEqual(registry.windowNumber(for: first), 1)
        XCTAssertEqual(registry.windowNumber(for: second), 2)
    }

    func testUnregisterRemovesOnlyThatSession() {
        let registry = ProjectSessionRegistry()
        let url = URL(fileURLWithPath: "/tmp/Shared.lungfish", isDirectory: true)
        let first = ProjectSession()
        let second = ProjectSession()
        registry.register(first, projectURL: url)
        registry.register(second, projectURL: url)

        registry.unregister(first)

        XCTAssertEqual(registry.sessions(forProjectURL: url).map(\.id), [second.id])
    }
}
