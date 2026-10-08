// ManagedStorageTestWriteGuard.swift - Stops test processes writing into real managed storage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// Stops a test process from installing into the user's real managed storage.
///
/// A unit test that reaches a default registry resolves the channel root under
/// the real home (`~/.lungfish-stable` for a SwiftPM xctest) and can download
/// hundreds of megabytes there. A write path calls ``checkWrite(to:operation:)``
/// before it touches disk, and inside a test process a destination under any
/// channel root or the shared root of the real home stops the process with the
/// offending path. Tests inject a root under the temporary directory instead.
///
/// Set `LUNGFISH_ALLOW_REAL_MANAGED_STORAGE_WRITES=1` for a deliberate live
/// install from a test process. Set `LUNGFISH_FORBID_REAL_MANAGED_STORAGE_WRITES=1`
/// to apply the guard to a process that is not a test runner, such as a
/// `lungfish-cli` subprocess a test starts.
public enum ManagedStorageTestWriteGuard {
    public static let allowEnvironmentKey = "LUNGFISH_ALLOW_REAL_MANAGED_STORAGE_WRITES"
    public static let forbidEnvironmentKey = "LUNGFISH_FORBID_REAL_MANAGED_STORAGE_WRITES"

    /// Stops the process when a test process is about to write `url` under a
    /// real managed storage root.
    public static func checkWrite(to url: URL, operation: String) {
        let environment = ProcessInfo.processInfo.environment
        guard let root = forbiddenRoot(
            containing: url,
            isTestProcess: isTestProcess,
            environment: environment,
            realHomeDirectory: realHomeDirectory
        ) else { return }
        fatalError(
            "\(operation) would write \(url.path) under the real managed storage root \(root.path). "
                + "Inject a storage root under the temporary directory, or set \(allowEnvironmentKey)=1 for a deliberate live install."
        )
    }

    /// The real managed storage root that contains `url`, when the guard applies.
    static func forbiddenRoot(
        containing url: URL,
        isTestProcess: Bool,
        environment: [String: String],
        realHomeDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard environment[allowEnvironmentKey] != "1" else { return nil }
        guard isTestProcess || environment[forbidEnvironmentKey] == "1" else { return nil }
        let target = canonicalPath(url)
        let roots = ManagedStorageChannelRoots.knownChannelRoots(homeDirectory: realHomeDirectory, fileManager: fileManager)
            + [ManagedStorageChannelRoots.sharedRootURL(homeDirectory: realHomeDirectory)]
        return roots.first { root in
            let rootPath = canonicalPath(root)
            return target == rootPath || target.hasPrefix(rootPath + "/")
        }
    }

    /// True inside an XCTest or Swift Testing runner.
    static let isTestProcess: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return true
        }
        if ["xctest", "swiftpm-testing-helper"].contains(ProcessInfo.processInfo.processName) {
            return true
        }
        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }()

    /// The account's home from the user database, so a test that points `HOME`
    /// at a temporary folder still names the real roots.
    static let realHomeDirectory: URL = {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    private static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
