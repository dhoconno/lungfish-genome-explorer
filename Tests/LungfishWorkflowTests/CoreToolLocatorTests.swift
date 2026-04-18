// CoreToolLocatorTests.swift - Tests for managed core tool resolution
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishCore

final class CoreToolLocatorTests: XCTestCase {

    func testManagedExecutableURLUsesLungfishCondaRoot() {
        let home = URL(fileURLWithPath: "/tmp/lungfish-home", isDirectory: true)
        let url = CoreToolLocator.executableURL(
            environment: "bbtools",
            executableName: "clumpify.sh",
            homeDirectory: home
        )

        XCTAssertEqual(
            url.path,
            "/tmp/lungfish-home/.lungfish/conda/envs/bbtools/bin/clumpify.sh"
        )
    }

    func testBBToolsEnvironmentUsesManagedJava() {
        let home = URL(fileURLWithPath: "/tmp/lungfish-home", isDirectory: true)
        let env = CoreToolLocator.bbToolsEnvironment(
            homeDirectory: home,
            existingPath: "/usr/bin:/bin"
        )

        XCTAssertEqual(env["JAVA_HOME"], "/tmp/lungfish-home/.lungfish/conda/envs/bbtools/lib/jvm")
        XCTAssertEqual(env["BBMAP_JAVA"], "/tmp/lungfish-home/.lungfish/conda/envs/bbtools/lib/jvm/bin/java")
        XCTAssertEqual(
            env["PATH"],
            "/tmp/lungfish-home/.lungfish/conda/envs/bbtools/bin:/usr/bin:/bin"
        )
    }

    func testManagedExecutableURLFallsBackToAlternatePath() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let envRoot = CoreToolLocator.environmentURL(named: "bbtools", homeDirectory: home)
        let fallbackJava = envRoot.appendingPathComponent("lib/jvm/bin/java")
        try? FileManager.default.createDirectory(at: fallbackJava.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "#!/bin/sh\nexit 0\n".write(to: fallbackJava, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fallbackJava.path)

        let resolved = CoreToolLocator.managedExecutableURL(
            environment: "bbtools",
            executableName: "java",
            homeDirectory: home,
            fallbackExecutablePaths: ["lib/jvm/bin/java"]
        )

        XCTAssertEqual(resolved.path, fallbackJava.path)
    }

    func testManagedExecutableURLUsesConfiguredManagedStorageRoot() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "core-tool-home-\(UUID().uuidString)",
            isDirectory: true
        )
        let configuredRoot = home.appendingPathComponent("managed-storage", isDirectory: true)
        let store = ManagedStorageConfigStore(homeDirectory: home)
        try store.setActiveRoot(configuredRoot)

        let url = CoreToolLocator.executableURL(
            environment: "bbtools",
            executableName: "clumpify.sh",
            homeDirectory: home
        )

        XCTAssertEqual(
            url.standardizedFileURL.path,
            configuredRoot
                .appendingPathComponent("conda/envs/bbtools/bin/clumpify.sh")
                .standardizedFileURL.path
        )
    }
}
