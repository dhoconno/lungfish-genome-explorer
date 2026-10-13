// CLIProcessLauncherChildEnvironmentTests.swift - A secret reaches the CLI child through its environment only
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishCore
@testable import LungfishKit

/// Review ruling Q2c of Phase 2.10 lane A44 (SWIFT 6). A launch carries a secret such as the NCBI
/// key in the child's environment, merged over the app's subprocess environment, and never in the
/// argv, the label or an error text. The child here is `/usr/bin/env`, which prints the
/// environment it got, so the test sees what a `lungfish-cli` child would see.
final class CLIProcessLauncherChildEnvironmentTests: XCTestCase {
    private static let notAKey = "lge-test-not-a-key"

    func testAnAdditionReachesTheChildAndNeitherItsArgvNorItsLabel() async throws {
        let spec = CLIProcessLauncher.spec(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            standardOutput: .captured,
            environmentAdditions: ["NCBI_API_KEY": Self.notAKey]
        )
        XCTAssertEqual(spec.environment["NCBI_API_KEY"], Self.notAKey)
        XCTAssertFalse(spec.arguments.contains { $0.contains(Self.notAKey) })
        XCTAssertFalse(spec.label.contains(Self.notAKey))
        XCTAssertNil(spec.environmentChange, "the provenance observer hears of no added variable")

        let outcome = await CLIProcessLauncher.run(spec, cancellation: CLIRunCancellation())
        guard case .exited(let exit) = outcome else {
            return XCTFail("env did not exit: \(outcome)")
        }
        XCTAssertEqual(exit.status, 0, exit.stderr)
        XCTAssertTrue(exit.stdout.split(separator: "\n").contains("NCBI_API_KEY=\(Self.notAKey)"))
    }

    func testAnAdditionWinsOverTheAppEnvironmentAndNoAdditionKeepsIt() {
        let base = ManagedStorageConfigStore().subprocessEnvironment()
        let url = URL(fileURLWithPath: "/usr/bin/env")
        XCTAssertEqual(CLIProcessLauncher.spec(executableURL: url, arguments: []).environment, base)
        let name = try? XCTUnwrap(base.keys.sorted().first)
        guard let name else { return }
        let replaced = CLIProcessLauncher.spec(executableURL: url, arguments: [], environmentAdditions: [name: "replaced"])
        XCTAssertEqual(replaced.environment[name], "replaced")
        XCTAssertEqual(replaced.environment.count, base.count)
    }
}
