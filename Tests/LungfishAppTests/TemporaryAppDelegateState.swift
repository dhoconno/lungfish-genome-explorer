import XCTest
@testable import LungfishApp

extension XCTestCase {
    @MainActor
    func makeAppDelegateWithTemporaryState() -> AppDelegate {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LGEWindowStateTest-\(UUID())")
        let delegate = AppDelegate()
        delegate.projectWindowStateStore = ProjectWindowStateStore(stateURL: directory.appendingPathComponent("windows.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return delegate
    }
}
