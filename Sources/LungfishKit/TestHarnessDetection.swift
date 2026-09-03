import Foundation

/// Whether this process is running under a test harness.
///
/// Code paths that would present modal UI, or write into the developer's real
/// support directories, need to know this. The usual signal is the
/// `XCTestConfigurationFilePath` environment variable, but the SwiftPM runner
/// this package uses sets no `XCTEST*` variables at all, so a check written
/// that way silently never fires. Probing for the loaded test framework works
/// under both SwiftPM and Xcode.
public enum TestHarness {
    /// True when a test framework is loaded into this process.
    public static let isRunning: Bool = {
        NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest") != nil
    }()
}
