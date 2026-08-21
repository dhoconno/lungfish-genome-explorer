// ToolAvailability.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Shared helper for tool-executing tests. By default, tests that need an
// external tool or database skip when it is not installed on this machine.
// Setting LUNGFISH_REQUIRE_TOOLS=1 turns those skips into hard failures, so
// a conformance run can assert the full toolset is actually present rather
// than silently going green on a machine that is missing tools.

import Foundation
import XCTest
import Testing
import LungfishWorkflow

public enum ToolAvailability {
    /// True when LUNGFISH_REQUIRE_TOOLS=1 is set in the environment.
    public static var requireTools: Bool {
        ProcessInfo.processInfo.environment["LUNGFISH_REQUIRE_TOOLS"] == "1"
    }

    /// Skips the current test (default) or fails it (LUNGFISH_REQUIRE_TOOLS=1).
    /// Always throws; the `Never` return type lets callers use it in a `guard ... else`
    /// or directly as the terminal statement of an availability check.
    ///
    /// For XCTest tests only. `XCTSkip`/`XCTFail` are not understood by
    /// swift-testing `@Test` functions; use `skipOrFailForSwiftTesting`
    /// (returns a Bool) there instead.
    public static func skipOrFail(_ reason: String, file: StaticString = #filePath, line: UInt = #line) throws -> Never {
        if requireTools {
            XCTFail("LUNGFISH_REQUIRE_TOOLS=1: \(reason)", file: file, line: line)
            throw ToolAvailabilityError.required(reason)
        }
        throw XCTSkip(reason, file: file, line: line)
    }

    /// swift-testing equivalent of `skipOrFail`. Under `LUNGFISH_REQUIRE_TOOLS=1`,
    /// records a failing `Issue` and returns `false`; a caller that treats a
    /// `false` return as "skip" would silently pass, so it must also propagate
    /// the failure (e.g. `guard ... else { throw ToolAvailabilityError.required(reason) }`).
    /// Without the flag, returns `false` so the caller can return early (skip).
    @discardableResult
    public static func skipOrFailForSwiftTesting(
        _ reason: String,
        sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) throws -> Bool {
        if requireTools {
            Issue.record(Comment(rawValue: "LUNGFISH_REQUIRE_TOOLS=1: \(reason)"), sourceLocation: sourceLocation)
            throw ToolAvailabilityError.required(reason)
        }
        return false
    }

    /// Resolves a tool executable in a managed conda environment, or skips/fails.
    public static func require(_ executable: String, environment: String, file: StaticString = #filePath, line: UInt = #line) async throws -> URL {
        do {
            return try await CondaManager.shared.toolPath(name: executable, environment: environment)
        } catch {
            try skipOrFail("\(executable) not installed in env \(environment): \(error)", file: file, line: line)
        }
    }

    /// Resolves a database via the given resolver, or skips/fails.
    public static func requireDatabase(_ resolver: () async throws -> URL?, name: String, file: StaticString = #filePath, line: UInt = #line) async throws -> URL {
        if let url = try await resolver(), FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        try skipOrFail("database \(name) not installed", file: file, line: line)
    }
}

public enum ToolAvailabilityError: Error {
    case required(String)
}

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum ProcessRunner {
    /// Runs a process and captures stdout/stderr.
    ///
    /// Pipe reads start on a background queue *before* `waitUntilExit`, and the
    /// wait itself polls rather than blocking the calling thread indefinitely, so
    /// a process that produces output larger than the pipe buffer cannot deadlock
    /// against `waitUntilExit` (the classic Foundation.Process pitfall). The
    /// `timeout` is still honored: once elapsed, the process is terminated and an
    /// error is thrown even if pipe draining is still in flight.
    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:], cwd: URL? = nil, timeout: TimeInterval = 600) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = executable.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env
        if let cwd {
            process.currentDirectoryURL = cwd
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain both pipes concurrently on background queues, starting before
        // the process even runs, so the OS pipe buffer never fills up and
        // blocks the child while nothing is reading.
        let stdoutData = ThreadSafeBox(Data())
        let stderrData = ThreadSafeBox(Data())
        let stdoutQueue = DispatchQueue(label: "ProcessRunner.stdout")
        let stderrQueue = DispatchQueue(label: "ProcessRunner.stderr")
        let stdoutDone = DispatchSemaphore(value: 0)
        let stderrDone = DispatchSemaphore(value: 0)

        // Signaled from `process.terminationHandler` the moment the process
        // exits, so the wait below is event-driven rather than a busy-poll.
        // The handler must be set before `run()` to avoid a race against an
        // already-exited process.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exited.signal()
        }

        try process.run()

        stdoutQueue.async {
            stdoutData.value = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutDone.signal()
        }
        stderrQueue.async {
            stderrData.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrDone.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        _ = exited.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow))
        if process.isRunning {
            process.terminate()
            throw ToolAvailabilityError.required("timeout running \(executable.lastPathComponent)")
        }

        // The process has exited; the readers will finish draining shortly
        // after (EOF unblocks readDataToEndOfFile). Wait for them so no
        // output is lost.
        let remaining = max(0, deadline.timeIntervalSinceNow) + 5
        _ = stdoutDone.wait(timeout: .now() + remaining)
        _ = stderrDone.wait(timeout: .now() + remaining)

        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData.value, as: UTF8.self),
            stderr: String(decoding: stderrData.value, as: UTF8.self)
        )
    }
}

/// Minimal lock-protected box for handing data between the pipe-draining
/// background queues and the calling thread.
private final class ThreadSafeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Data

    init(_ value: Data) {
        self._value = value
    }

    var value: Data {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }
}
