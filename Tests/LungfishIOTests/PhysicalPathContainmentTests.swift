// PhysicalPathContainmentTests.swift - /tmp vs /private/tmp containment
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class PhysicalPathContainmentTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("physical-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTmpAliasesNestEitherWay() throws {
        guard FileManager.default.fileExists(atPath: "/private/tmp"),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: "/tmp")) != nil else {
            throw XCTSkip("/tmp is not a symbolic link on this system.")
        }
        let name = "lge-physical-path-\(UUID().uuidString)"
        let privateDirectory = URL(fileURLWithPath: "/private/tmp/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: privateDirectory) }
        let aliasDirectory = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
        let notYetWritten = privateDirectory.appendingPathComponent("artifacts/projections/rows.json")

        // The trap: Foundation shortens only the existing directory.
        XCTAssertFalse(
            notYetWritten.standardizedFileURL.path
                .hasPrefix(privateDirectory.standardizedFileURL.path + "/")
        )

        for directory in [privateDirectory, aliasDirectory] {
            XCTAssertEqual(
                PhysicalPathContainment.relativePath(of: notYetWritten, within: directory),
                "artifacts/projections/rows.json"
            )
            XCTAssertEqual(
                PhysicalPathContainment.relativePath(
                    of: aliasDirectory.appendingPathComponent("x.json"),
                    within: directory
                ),
                "x.json"
            )
        }
    }

    func testOutsideSiblingAndTheDirectoryItselfAreNotContained() {
        let directory = root.appendingPathComponent("bundle", isDirectory: true)
        let sibling = root.appendingPathComponent("bundle-other/file.json")
        XCTAssertNil(PhysicalPathContainment.relativePath(of: sibling, within: directory))
        XCTAssertNil(PhysicalPathContainment.relativePath(of: directory, within: directory))
        XCTAssertNil(PhysicalPathContainment.relativePath(
            of: directory.appendingPathComponent("../escape.json"),
            within: directory
        ))
    }

    func testSymbolicLinkInsideTheDirectoryIsResolved() throws {
        let directory = root.appendingPathComponent("bundle", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link"),
            withDestinationURL: outside
        )
        XCTAssertNil(PhysicalPathContainment.relativePath(
            of: directory.appendingPathComponent("link/file.json"),
            within: directory
        ))
    }
}
