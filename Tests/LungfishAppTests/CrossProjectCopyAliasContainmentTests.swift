// CrossProjectCopyAliasContainmentTests.swift - A copy into itself through a folder alias is refused
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane 12.18 found this at the base. The copier checked containment on the
// resolved paths, but a destination that does not exist yet resolves no link,
// so a drop target reached through a symlinked alias of the source project
// passed the check and the native copy copied the item into itself until the
// name grew too long.

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

final class CrossProjectCopyAliasContainmentTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("CrossProjectCopyAliasContainmentTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    func testDestinationInsideTheSourceThroughAnAliasIsRefusedAndWritesNothing() throws {
        let project = root.appendingPathComponent("Source.lungfish", isDirectory: true)
        let ref = project.appendingPathComponent("Reference Sequences/NC_045512.lungfishref", isDirectory: true)
        try fm.createDirectory(at: ref, withIntermediateDirectories: true)
        try "{\"bundleKind\":\"fixture\"}".write(to: ref.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let alias = root.appendingPathComponent("Alias.lungfish", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: project)
        let requested = alias.appendingPathComponent("Reference Sequences/NC_045512.lungfishref", isDirectory: true)

        XCTAssertThrowsError(try CrossProjectItemCopier.copy(itemAt: ref, intoProject: alias, requestedFolder: requested, identity: .neutral)) { error in
            guard case CrossProjectItemCopier.CopyError.destinationInsideSource = error else {
                return XCTFail("expected destinationInsideSource, got \(error)")
            }
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: ref.path), ["manifest.json"])
    }
}
