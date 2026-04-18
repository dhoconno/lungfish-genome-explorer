// SRAServicePathTests.swift - Managed SRA toolkit path coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

final class SRAServicePathTests: XCTestCase {

    func testManagedToolkitExecutableURLUsesLungfishCondaLayout() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sra-home-\(UUID().uuidString)",
            isDirectory: true
        )

        let url = SRAService.managedExecutableURL(
            executableName: "prefetch",
            homeDirectory: home
        )

        XCTAssertEqual(
            url.path,
            home.appendingPathComponent(".lungfish/conda/envs/sra-tools/bin/prefetch").path
        )
    }

    func testManagedToolkitExecutableURLUsesConfiguredManagedStorageRoot() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sra-home-\(UUID().uuidString)",
            isDirectory: true
        )
        let configuredRoot = home.appendingPathComponent("shared-storage", isDirectory: true)
        let store = ManagedStorageConfigStore(homeDirectory: home)
        try store.setActiveRoot(configuredRoot)

        let url = SRAService.managedExecutableURL(
            executableName: "prefetch",
            homeDirectory: home
        )

        XCTAssertEqual(
            url.standardizedFileURL.path,
            configuredRoot
                .appendingPathComponent("conda/envs/sra-tools/bin/prefetch")
                .standardizedFileURL.path
        )
    }

    func testToolkitAvailabilityUsesManagedLayout() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sra-home-\(UUID().uuidString)",
            isDirectory: true
        )
        let binDir = home.appendingPathComponent(".lungfish/conda/envs/sra-tools/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try makeExecutableScript(
            at: binDir.appendingPathComponent("prefetch"),
            body: "#!/bin/sh\nexit 0\n"
        )
        try makeExecutableScript(
            at: binDir.appendingPathComponent("fasterq-dump"),
            body: "#!/bin/sh\nexit 0\n"
        )

        let service = SRAService(homeDirectoryProvider: { home })
        let available = await service.isSRAToolkitAvailable

        XCTAssertTrue(available)
    }

    func testToolkitAvailabilityUsesConfiguredManagedStorageRoot() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sra-home-\(UUID().uuidString)",
            isDirectory: true
        )
        let configuredRoot = home.appendingPathComponent("shared-storage", isDirectory: true)
        let store = ManagedStorageConfigStore(homeDirectory: home)
        try store.setActiveRoot(configuredRoot)

        let binDir = configuredRoot.appendingPathComponent("conda/envs/sra-tools/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try makeExecutableScript(
            at: binDir.appendingPathComponent("prefetch"),
            body: "#!/bin/sh\nexit 0\n"
        )
        try makeExecutableScript(
            at: binDir.appendingPathComponent("fasterq-dump"),
            body: "#!/bin/sh\nexit 0\n"
        )

        let service = SRAService(homeDirectoryProvider: { home })
        let available = await service.isSRAToolkitAvailable

        XCTAssertTrue(available)
    }
}

private func makeExecutableScript(at url: URL, body: String) throws {
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}
