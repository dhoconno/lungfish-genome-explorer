import XCTest
@testable import LungfishApp
import LungfishTestSupport

extension XCTestCase {
    /// The keys `RecentProjectsManager` writes to `UserDefaults.standard` when a project opens. It has no defaults
    /// seam, so a test that opens a project puts them back.
    static let recentProjectHostDefaultsKeys: Set<String> = ["com.lungfish.recentProjects", "com.lungfish.lastProject"]

    /// Puts back the named keys of the test host's own defaults when the test ends, for product code that writes a
    /// fixed key to `UserDefaults.standard` with no seam (search history, app settings, panel states). Call it in
    /// `setUp`, or in a test before the code that writes. Its teardown block runs before `tearDown`, so a key that
    /// `tearDown` itself writes needs a ``HostDefaultsRestorer`` restored at the end of `tearDown` instead.
    func restoreHostDefaultsAfterTest(keys: Set<String>) {
        let hostDefaults = HostDefaultsRestorer(keys: keys)
        addTeardownBlock { _ = hostDefaults.restore() }
    }

    /// An app delegate whose window state goes to a temporary file. When the test ends, the delegate's project
    /// windows close and the recent and last project keys go back to what they were, so the test leaves no window and
    /// no host defaults key (Phase 3.1 ruling QA-RELEASE-LOOP, section 5).
    @MainActor
    func makeAppDelegateWithTemporaryState() -> AppDelegate {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LGEWindowStateTest-\(UUID())")
        let delegate = AppDelegate()
        delegate.projectWindowStateStore = ProjectWindowStateStore(stateURL: directory.appendingPathComponent("windows.json"))
        let hostDefaults = HostDefaultsRestorer(keys: Self.recentProjectHostDefaultsKeys)
        // A window the delegate no longer lists, such as a closed duplicate's survivor or an import alert's host.
        orderOutWindowsOpenedDuringTest()
        addTeardownBlock { @MainActor in
            delegate.testingMainWindowControllers.forEach { $0.close() }
            hostDefaults.restore()
            try? FileManager.default.removeItem(at: directory)
        }
        return delegate
    }
}
