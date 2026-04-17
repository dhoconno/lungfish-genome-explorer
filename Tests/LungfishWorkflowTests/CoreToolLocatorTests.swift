// CoreToolLocatorTests.swift - Tests for managed core tool resolution
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

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
}
