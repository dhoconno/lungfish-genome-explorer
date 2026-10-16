// TestDefaultsSuite.swift - A UserDefaults suite for one test that leaves no plist behind
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

/// A `UserDefaults` suite with a unique name, for a test that needs defaults of its own.
///
/// A suite named by a plain string, `UserDefaults(suiteName: "Foo-<UUID>")`, is written by the
/// preferences daemon to `~/Library/Preferences/Foo-<UUID>.plist`, and
/// `removePersistentDomain(forName:)` only empties that file. A suite built that way therefore left
/// one empty plist in the folder per test, which is how thousands piled up. Removing the file
/// afterwards does not help either, because the daemon writes the emptied domain again one to four
/// seconds later (measured in Phase 2.9, lane Q10).
///
/// This helper names the suite by an absolute path in the temporary directory,
/// `<tmp>/TestDefaultsSuite/<prefix>-<UUID>`. The system stores such a suite at that path plus
/// `.plist`, never in `~/Library/Preferences`, and nothing writes it again once `tearDown()` has
/// emptied the domain and removed the file.
///
/// Name the prefix after the test class, `TestDefaultsSuite(prefix: "WorkflowLibraryTests")`, with
/// the prefix as a literal so `scripts/testing/preferences-leaks.py` can see it. A test that wants
/// the suite removed when it ends calls `makeTestDefaultsSuite(prefix:)` on the test case instead.
/// The script, which `scripts/full-suite-gate.sh` runs around every tier, fails on a plist that a
/// test left in `~/Library/Preferences`.
///
/// The class is `@unchecked Sendable` because its two properties never change after `init` and
/// Apple documents `UserDefaults` as safe to use from any thread, but the SDK has not marked it
/// `Sendable`.
public final class TestDefaultsSuite: @unchecked Sendable {
    /// The suite name, an absolute path ending in `<prefix>-<UUID>`.
    public let name: String
    /// The defaults of the suite.
    public let defaults: UserDefaults

    public init(prefix: String) {
        precondition(!prefix.contains("/"), "a TestDefaultsSuite prefix is part of a file name, not a path")
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let name = Self.folder.appendingPathComponent("\(prefix)-\(UUID().uuidString)").path
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("UserDefaults(suiteName:) refused the suite name \(name)")
        }
        self.name = name
        self.defaults = defaults
    }

    /// Another handle on the same suite, for code that opens the suite by name.
    public func makeDefaults() -> UserDefaults {
        guard let handle = UserDefaults(suiteName: name) else {
            preconditionFailure("UserDefaults(suiteName:) refused the suite name \(name)")
        }
        return handle
    }

    /// The folder that holds the plist of every suite, in the temporary directory of the process.
    public static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TestDefaultsSuite", isDirectory: true)
    }

    /// The file the system writes for this suite.
    public var plistURL: URL {
        URL(fileURLWithPath: name + ".plist")
    }

    /// Empties the suite and removes its plist. Call it from `tearDown()` or a teardown block, and
    /// again if you like.
    public func tearDown() {
        defaults.removePersistentDomain(forName: name)
        // Make the system write the emptied domain now, so that no later write follows the removal.
        _ = defaults.synchronize()
        try? FileManager.default.removeItem(at: plistURL)
    }
}

extension XCTestCase {
    /// Makes a `TestDefaultsSuite` named `<prefix>-<UUID>` and tears it down when the current
    /// test ends.
    ///
    /// XCTest runs a test's teardown blocks, last in and first out, before the instance
    /// `tearDown()` (`TeardownBlockOrderTests` pins the order). A `tearDown()` that still writes to
    /// the suite would therefore create the plist again after the block removed it, so the suite is
    /// torn down a second time when the test case finishes, which is after `tearDown()` has run.
    public func makeTestDefaultsSuite(prefix: String) -> TestDefaultsSuite {
        let suite = TestDefaultsSuite(prefix: prefix)
        addTeardownBlock { suite.tearDown() }
        TestDefaultsSuiteSweeper.shared.register(suite, for: self)
        return suite
    }
}

/// Tears down the suites that `makeTestDefaultsSuite(prefix:)` made for a test case once that case
/// has finished, after its `tearDown()`. XCTest calls `testCaseDidFinish(_:)` exactly once per case.
///
/// XCTest accepts an observer on the main thread only. Anywhere else it throws
/// `NSInternalInconsistencyException` ("Test observers can only be registered and unregistered on the
/// main thread"), and a nonisolated `async` test runs on a cooperative thread. The sign-up therefore
/// cannot run in the initializer of `shared`, which runs on the thread of the first caller.
/// `register(_:for:)` signs the sweeper up instead, on the main thread whichever thread calls it
/// (Phase 2.11 tier 1, cause D2, pinned by `TestDefaultsSuiteObserverThreadTests`).
///
/// The class is `@unchecked Sendable` because the lock guards every property.
public final class TestDefaultsSuiteSweeper: NSObject, XCTestObservation, @unchecked Sendable {
    /// The sweeper, signed up with XCTest the first time a suite is registered.
    public static let shared = TestDefaultsSuiteSweeper()

    private enum SignUp {
        case notRequested
        /// A caller off the main thread queued the sign-up on the main queue and it has not run yet.
        case queued
        case done
    }

    private let lock = NSLock()
    private var suites: [ObjectIdentifier: [TestDefaultsSuite]] = [:]
    private var signUp = SignUp.notRequested

    /// Whether XCTest has the sweeper as an observer.
    public var isObserving: Bool {
        lock.lock()
        defer { lock.unlock() }
        return signUp == .done
    }

    /// Remembers `suite` until `testCase` finishes, and makes sure XCTest tells the sweeper when that is.
    public func register(_ suite: TestDefaultsSuite, for testCase: XCTestCase) {
        lock.lock()
        suites[ObjectIdentifier(testCase), default: []].append(suite)
        lock.unlock()
        observeTestCases()
    }

    /// Signs the sweeper up with XCTest, once, on the main thread.
    ///
    /// A caller on the main thread signs up at once. A caller off it queues the sign-up on the main queue and
    /// returns without waiting for it, because the main thread can be waiting for this very caller (XCTest
    /// waits there for an `async` test to end) and waiting here would deadlock. XCTest keeps the main queue
    /// running while it waits, so the sign-up lands long before the case ends. A case that ended first would
    /// be left to its teardown blocks, which already remove every suite it made.
    private func observeTestCases() {
        if Thread.isMainThread {
            signUpOnTheMainThread()
            return
        }
        lock.lock()
        let shouldQueue = signUp == .notRequested
        if shouldQueue { signUp = .queued }
        lock.unlock()
        if shouldQueue {
            DispatchQueue.main.async { self.signUpOnTheMainThread() }
        }
    }

    /// Runs on the main thread only, as a direct call or as a block of the main queue, so two sign-ups never overlap.
    private func signUpOnTheMainThread() {
        lock.lock()
        let needed = signUp != .done
        lock.unlock()
        guard needed else { return }
        XCTestObservationCenter.shared.addTestObserver(self)
        lock.lock()
        signUp = .done
        lock.unlock()
    }

    public func testCaseDidFinish(_ testCase: XCTestCase) {
        lock.lock()
        let finished = suites.removeValue(forKey: ObjectIdentifier(testCase)) ?? []
        lock.unlock()
        for suite in finished { suite.tearDown() }
    }
}
