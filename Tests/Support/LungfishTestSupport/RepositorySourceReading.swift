// RepositorySourceReading.swift - EINTR-proof reads of repository files for source-scanning tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The parallel unit gate twice failed a source-scanning test when
// `String(contentsOf:)` threw NSCocoaErrorDomain 256 with an underlying
// NSPOSIXErrorDomain 4 ("Interrupted system call"). A read cut short by a
// signal is not a test failure. These helpers retry it a few times and throw
// every other error unchanged.

import Foundation

/// Whether `error`, or any error it wraps, is EINTR.
public func isInterruptedSystemCall(_ error: Error) -> Bool {
    if let posix = error as? POSIXError, posix.code == .EINTR {
        return true
    }
    var current: NSError? = error as NSError
    var depth = 0
    while let nsError = current, depth < 8 {
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EINTR) {
            return true
        }
        current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        depth += 1
    }
    return false
}

/// Runs `body` again when it throws EINTR, up to `attempts` times in all.
/// Any other error, or the last EINTR, is thrown.
public func retryingInterruptedSystemCalls<T>(
    attempts: Int = 5,
    _ body: () throws -> T
) throws -> T {
    var attempt = 1
    while true {
        do {
            return try body()
        } catch where attempt < attempts && isInterruptedSystemCall(error) {
            attempt += 1
        }
    }
}

/// Reads a UTF-8 text file from the repository, retrying a read that a signal
/// interrupted. Use it in place of `String(contentsOf: url, encoding: .utf8)`
/// in tests that scan source, docs, or script files.
public func readRepositorySource(_ url: URL) throws -> String {
    try retryingInterruptedSystemCalls {
        try String(contentsOf: url, encoding: .utf8)
    }
}

/// Path form of `readRepositorySource(_:)`.
public func readRepositorySource(atPath path: String) throws -> String {
    try readRepositorySource(URL(fileURLWithPath: path))
}

/// Every regular file under `root` whose extension is in `pathExtensions`
/// (all regular files when it is empty), sorted by path. Hidden files are
/// skipped. A walk that a signal interrupted is started again, and any other
/// enumeration error is thrown instead of being dropped silently.
public func repositoryFiles(
    under root: URL,
    withExtensions pathExtensions: Set<String> = ["swift"]
) throws -> [URL] {
    try retryingInterruptedSystemCalls {
        var walkError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                walkError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard pathExtensions.isEmpty || pathExtensions.contains(url.pathExtension) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(url)
            }
        }
        if let walkError { throw walkError }
        return files.sorted { $0.path < $1.path }
    }
}
