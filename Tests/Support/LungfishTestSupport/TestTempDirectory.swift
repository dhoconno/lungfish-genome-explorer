import Foundation

/// Shared helper for creating and tearing down per-test scratch directories.
///
/// Replaces the ~100+ private, near-identical copies of:
///
///     let root = FileManager.default.temporaryDirectory
///         .appendingPathComponent("some-prefix-\(UUID().uuidString)", isDirectory: true)
///     defer { try? FileManager.default.removeItem(at: root) }
///     try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
///
/// scattered across the test suite.
public enum TestTempDirectory {
    /// Creates a unique directory under `FileManager.default.temporaryDirectory` and
    /// returns it. The directory (and all intermediate directories) already exist
    /// when this returns. The caller is responsible for removing it, typically via
    /// `defer { TestTempDirectory.cleanup(url) }` immediately after creation, or in
    /// `tearDown()`.
    public static func make(prefix: String = "lungfish-test") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Removes the directory at `url`, ignoring any error (missing directory,
    /// permission issues, etc). Intended for `defer` blocks where cleanup failure
    /// should never fail the test.
    public static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
