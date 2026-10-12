// TestDefaultsSuiteTests.swift - The shared defaults suite leaves nothing in ~/Library/Preferences
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishTestSupport
import XCTest

final class TestDefaultsSuiteTests: XCTestCase {
    private let prefix = "TestDefaultsSuiteTests"

    func testEachSuiteHasItsOwnNameThatKeepsThePrefix() {
        let first = TestDefaultsSuite(prefix: "TestDefaultsSuiteTests")
        let second = TestDefaultsSuite(prefix: "TestDefaultsSuiteTests")
        defer {
            first.tearDown()
            second.tearDown()
        }

        XCTAssertNotEqual(first.name, second.name)
        for suite in [first, second] {
            let file = URL(fileURLWithPath: suite.name).lastPathComponent
            XCTAssertTrue(file.hasPrefix("\(prefix)-"), file)
            XCTAssertNotNil(UUID(uuidString: String(file.dropFirst(prefix.count + 1))), file)
            XCTAssertEqual(suite.plistURL.path, suite.name + ".plist")
            XCTAssertEqual(suite.plistURL.deletingLastPathComponent().path, TestDefaultsSuite.folder.path)
        }
    }

    func testTearDownEmptiesTheDomainForEveryHandle() {
        let suite = TestDefaultsSuite(prefix: "TestDefaultsSuiteTests")
        let other = suite.makeDefaults()
        suite.defaults.set("kept", forKey: "key")
        XCTAssertEqual(other.string(forKey: "key"), "kept", "a second handle sees the same suite")

        suite.tearDown()

        XCTAssertNil(other.string(forKey: "key"))
        XCTAssertNil(suite.defaults.string(forKey: "key"))
        suite.tearDown()
    }

    /// The system must store the suite beside the temporary folder. A suite named by a plain string
    /// goes to ~/Library/Preferences, where the plists of a test run piled up in their thousands.
    func testTheSuiteIsStoredInTheTemporaryFolderAndNotInPreferences() {
        let suite = TestDefaultsSuite(prefix: "TestDefaultsSuiteTests")
        defer { suite.tearDown() }
        suite.defaults.set("value", forKey: "key")
        suite.defaults.synchronize()

        XCTAssertTrue(
            waitUntil { FileManager.default.fileExists(atPath: suite.plistURL.path) },
            "the system never wrote \(suite.plistURL.path)"
        )
        let inPreferences = preferencesFolder.appendingPathComponent(suite.plistURL.lastPathComponent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inPreferences.path), "wrote \(inPreferences.path)")
    }

    /// `removePersistentDomain(forName:)` alone leaves the emptied plist, so a test that stopped
    /// there left one `<Class>-<UUID>.plist` behind per test.
    func testTearDownRemovesThePlistTheSystemWrote() {
        let suite = TestDefaultsSuite(prefix: "TestDefaultsSuiteTests")
        suite.defaults.set("value", forKey: "key")
        suite.defaults.synchronize()
        XCTAssertTrue(
            waitUntil { FileManager.default.fileExists(atPath: suite.plistURL.path) },
            "the system never wrote \(suite.plistURL.path), so the test cannot show the teardown removes it"
        )

        suite.tearDown()

        XCTAssertFalse(FileManager.default.fileExists(atPath: suite.plistURL.path), "left \(suite.plistURL.path)")
        XCTAssertFalse(
            waitUntil(timeout: 2) { FileManager.default.fileExists(atPath: suite.plistURL.path) },
            "the system wrote \(suite.plistURL.path) back after the teardown"
        )
    }

    func testTearDownWithoutAWrittenPlistIsHarmless() {
        let suite = TestDefaultsSuite(prefix: "TestDefaultsSuiteTests")
        XCTAssertFalse(FileManager.default.fileExists(atPath: suite.plistURL.path))
        suite.tearDown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: suite.plistURL.path))
    }

    func testMakeTestDefaultsSuiteTearsTheSuiteDownWhenTheTestEnds() {
        let probe = TeardownProbe()
        // Teardown blocks run last in, first out, so this check runs after the suite's own block.
        addTeardownBlock {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: probe.plistPath),
                "makeTestDefaultsSuite left \(probe.plistPath) after the test ended"
            )
        }
        let suite = makeTestDefaultsSuite(prefix: "TestDefaultsSuiteTests")
        probe.name = suite.name
        probe.plistPath = suite.plistURL.path

        suite.defaults.set("value", forKey: "key")
        suite.defaults.synchronize()
        XCTAssertTrue(
            waitUntil { FileManager.default.fileExists(atPath: suite.plistURL.path) },
            "the system never wrote \(suite.plistURL.path)"
        )
    }

    // MARK: - Helpers

    private final class TeardownProbe: @unchecked Sendable {
        var name = ""
        var plistPath = ""
    }

    private var preferencesFolder: URL {
        URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    /// Polls `condition` every 50 ms and returns true as soon as it holds, false at the timeout.
    private func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }
}
