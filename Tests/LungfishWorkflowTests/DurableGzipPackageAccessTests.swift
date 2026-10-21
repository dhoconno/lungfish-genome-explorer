// DurableGzipPackageAccessTests.swift - Another module runs a stand-in through DurableGzip's compressor entry
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.17 M2 (3). `DurableGzip.compress(source:to:using:cancellation:)` is `package`, so lane 13.39
// can reuse the streaming, part-file and publish rules of the gzip helper with another compressor. This class
// imports LungfishCore without `@testable`, so it fails to compile if the entry goes back to internal, and it
// runs a stand-in that follows the command line (`-c <source>`) through the entry.

import LungfishCore
import XCTest

final class DurableGzipPackageAccessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DurableGzipPackageAccess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func standIn(_ body: String) throws -> URL {
        let script = root.appendingPathComponent("stand-in")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func testAStandInThatFollowsTheCommandLineRunsThroughThePackageEntry() throws {
        let source = root.appendingPathComponent("in.txt")
        try "package access\n".write(to: source, atomically: true, encoding: .utf8)
        let destination = root.appendingPathComponent("out.gz")
        // The stand-in copies its source argument to standard output, as `gzip -c <source>` writes its result there.
        let script = try standIn("exec /bin/cat \"$2\"")

        try DurableGzip.compress(source: source, to: destination, using: script, cancellation: nil)

        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
    }

    func testAFailingStandInPublishesNothingAndReportsItsStatus() throws {
        let destination = root.appendingPathComponent("never.gz")
        let script = try standIn("echo broke >&2\nexit 3")
        XCTAssertThrowsError(
            try DurableGzip.compress(source: root.appendingPathComponent("unused"), to: destination, using: script, cancellation: nil)
        ) { error in
            XCTAssertEqual(error as? DurableGzipError, .gzipFailed(exitCode: 3, stderr: "broke\n"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
