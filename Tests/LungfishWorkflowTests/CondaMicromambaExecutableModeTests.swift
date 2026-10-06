// CondaMicromambaExecutableModeTests.swift - micromamba's mode is written only when it must change
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow

final class CondaMicromambaExecutableModeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conda-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAlreadyExecutableBinaryIsNotWritten() throws {
        let binary = directory.appendingPathComponent("micromamba")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let before = try statusChangeTime(binary)

        try CondaManager.makeExecutableIfNeeded(at: binary)

        XCTAssertEqual(try statusChangeTime(binary), before, "an executable binary must not be chmod-ed again")
    }

    func testNonExecutableBinaryBecomesExecutable() throws {
        let binary = directory.appendingPathComponent("micromamba")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: binary.path)

        try CondaManager.makeExecutableIfNeeded(at: binary)

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
    }

    private func statusChangeTime(_ url: URL) throws -> Int {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        return info.st_ctimespec.tv_sec * 1_000_000_000 + info.st_ctimespec.tv_nsec
    }
}
