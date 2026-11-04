// CrossProjectFolderResultCopyTests+FolderLink.swift - A link to a folder inside a result is refused in plain words
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane COPYFOLDER, finding 3 of report 2 and COPYFOLDER-UX backlog 1. A result folder that holds a link to a
// folder reached a person as `Import requires a concrete directory; directory links are unsupported at <Target>.lungfish/.tmp/
// project-copy-<id>/.native-copy-<id>/<link>.` after a drag in the sidebar. The copy follows a link to a file and cannot follow
// a link to a folder, so it is still refused, in words that name the person's item and the link, say what to try and show
// no hidden path.

import XCTest
import LungfishCore
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

extension CrossProjectFolderResultCopyTests {
    func testAFolderLinkInsideAResultIsRefusedInPlainWords() async throws {
        let source = try await buildWithRecord(.kraken2)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let pointedTo = elsewhere.appendingPathComponent("a.txt")
        try "reads\n".write(to: pointedTo, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: source.appendingPathComponent("reads"), withDestinationURL: elsewhere)
        let before = try treeDigest(of: source)

        let message = try refusal(of: source)

        expectPlainWords(message, item: source.lastPathComponent)
        XCTAssertTrue(message.contains("reads in \(source.lastPathComponent) is a link to a folder"), "names the link: \(message)")
        for hidden in ["directory links are unsupported", "Import requires", ".native-copy-", targetProject.path, root.path] {
            XCTAssertFalse(message.contains(hidden), "\(hidden) in: \(message)")
        }
        try expectNothingLeftInTarget()
        XCTAssertEqual(try treeDigest(of: source), before, "the refused source is untouched")
        XCTAssertTrue(fm.fileExists(atPath: pointedTo.path), "the folder the link points to is untouched")
    }

    /// A link to a file still copies, as the file it points to.
    func testAFileLinkInsideAResultStillCopies() async throws {
        let source = try await buildWithRecord(.kraken2)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let pointedTo = elsewhere.appendingPathComponent("a.txt")
        try "reads\n".write(to: pointedTo, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: source.appendingPathComponent("reads.txt"), withDestinationURL: pointedTo)

        let outcome = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject, identity: .neutral)

        let copied = outcome.destinationURL.appendingPathComponent("reads.txt")
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "reads\n")
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: copied.path), "the copy holds the file and not a link")
        XCTAssertEqual(stages(), [])
    }
}
