// AppDelegateProjectWindowFocusTests.swift - NEW-03: focus an already-open
// project instead of creating a second window for it.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class AppDelegateProjectWindowFocusTests: XCTestCase {
    /// `AppDelegate.controller(forProjectURL:)` backs both `openRecentProjectFromMenu`
    /// and `openProjectFolder`'s "focus instead of duplicate" check. Before NEW-03,
    /// neither call site consulted it at all, so picking an already-open project from
    /// File > Open Recent (or the folder picker) always created a second window.
    func testControllerForProjectURLFindsTheWindowAlreadyOpenOnThatProject() throws {
        _ = NSApplication.shared
        let delegate = makeAppDelegateWithTemporaryState()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateProjectWindowFocusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        let session = ProjectSession()
        _ = try session.createProject(at: projectURL, name: "Fixture")
        let opened = delegate.createAndShowMainWindow(projectSession: session)
        opened.window?.setFrameAutosaveName("")
        defer { opened.close() }

        // A second, unrelated open window must not be mistaken for a match.
        let unrelated = delegate.createAndShowMainWindow()
        unrelated.window?.setFrameAutosaveName("")
        defer { unrelated.close() }

        XCTAssertTrue(delegate.controller(forProjectURL: projectURL) === opened)

        // Equivalent-but-differently-constructed URLs for the same folder
        // must resolve to the same open window (matches the canonicalization
        // `openProject(_:in:)` and `ProjectSessionRegistry` already use).
        let withTrailingSlash = URL(fileURLWithPath: projectURL.path, isDirectory: true)
        XCTAssertTrue(delegate.controller(forProjectURL: withTrailingSlash) === opened)

        XCTAssertNil(delegate.controller(forProjectURL: root.appendingPathComponent("NeverOpened.lungfish")))
    }
}
