// WelcomeWindowControllerTests.swift - A project folder that Finder named `P.lungfish copy` is a project
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane PROJECT-ROOT (walk WF-2b and WF-3). Finder names a copy of `P.lungfish` `P.lungfish copy`.
// File > Open Project Folder… opens it as a project, so the Welcome window opens it without asking
// "Open as Working Directory?", and the viewer takes it as the project a new bundle goes into.

import AppKit
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishApp

@MainActor
final class WelcomeWindowControllerTests: XCTestCase {

    /// At the base the name `P.lungfish copy` has no `.lungfish` extension, so Welcome asks first.
    func testOpenProjectOnFinderCopyOpensWithoutAsking() throws {
        _ = NSApplication.shared
        let copy = try makeFinderCopy(in: makeTestRoot(self, prefix: "welcome-project-copy"))
        let welcome = WelcomeWindowController()
        defer { close(welcome) }
        var selected: URL?
        welcome.onProjectSelected = { selected = $0 }

        welcome.openProject(at: copy)

        XCTAssertEqual(selected?.path, copy.path, "the copy goes straight to the project open")
        XCTAssertNil(welcome.window?.attachedSheet, "no Open as Working Directory? question")
    }

    /// A folder that is not a project still asks, and opens nothing until the person answers.
    func testOpenProjectOnPlainFolderAsks() throws {
        _ = NSApplication.shared
        let folder = try makeTestRoot(self, prefix: "welcome-plain-folder")
            .appendingPathComponent("Plain Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let welcome = WelcomeWindowController()
        defer { close(welcome) }
        var selected: URL?
        welcome.onProjectSelected = { selected = $0 }

        welcome.openProject(at: folder)

        XCTAssertNil(selected, "a plain folder opens only after the question")
        XCTAssertNotNil(welcome.window?.attachedSheet, "the Open as Working Directory? question is shown")
    }

    private func close(_ welcome: WelcomeWindowController) {
        if let window = welcome.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
        welcome.close()
    }
}

@MainActor
final class ViewerEnclosingProjectURLTests: XCTestCase {

    /// Extract to New Bundle… writes into the project that holds the shown bundle. At the base a Finder copy is no
    /// project to `enclosingProjectURL`, so the extraction returned with no word.
    func testEnclosingProjectURLFindsFinderCopy() throws {
        let copy = try makeFinderCopy(in: makeTestRoot(self, prefix: "viewer-project-copy"))
        let bundle = copy.appendingPathComponent("Reference Sequences/ref.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        XCTAssertEqual(ViewerViewController.enclosingProjectURL(for: bundle)?.standardizedFileURL, copy.standardizedFileURL)
    }
}

/// A temporary folder that goes when `test` ends.
@MainActor
private func makeTestRoot(_ test: XCTestCase, prefix: String) throws -> URL {
    let root = try TestTempDirectory.make(prefix: prefix)
    test.addTeardownBlock { TestTempDirectory.cleanup(root) }
    return root
}

/// `P.lungfish`, made as the app makes a project, and its Finder copy `P.lungfish copy`, which is returned.
@MainActor
private func makeFinderCopy(in root: URL) throws -> URL {
    let original = root.appendingPathComponent("P.lungfish", isDirectory: true)
    _ = try ProjectFile.create(at: original, name: "P")
    let copy = root.appendingPathComponent("P.lungfish copy", isDirectory: true)
    try FileManager.default.copyItem(at: original, to: copy)
    return copy
}
