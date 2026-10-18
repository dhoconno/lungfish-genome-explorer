// RouteParityHarnessRebaseTests.swift - The harness rebase moves the path of a `--name=<path>` word
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.16 M1 (1), ruling 3 of the A67 review. `RouteParityHarness.rebased` moved only a word that
// starts with root A and threw `argumentOutsideRoot` for `--output=<root A>/x`, so a builder had to spell a path
// option as two words. It now splits a long option at its first `=` and moves the value when the value starts with
// root A. The two-word spelling still moves, and a word that names root A anywhere else still throws, since a
// replay would then read or write the first run's files. Pure, so it runs in the unit tier.

import Foundation
import XCTest
import LungfishKit
import LungfishKitTestSupport

final class RouteParityHarnessRebaseTests: XCTestCase {
    private let rootA = URL(fileURLWithPath: "/tmp/lungfish-rebase/A", isDirectory: true)
    private let rootB = URL(fileURLWithPath: "/tmp/lungfish-rebase/B", isDirectory: true)

    private func command(_ args: [String]) -> String {
        OperationCenter.buildCLICommand(subcommand: "primers design primer3", args: args)
    }

    func testALongOptionWithItsPathInOneWordMovesThePath() throws {
        let joined = command([
            "--output=\(rootA.path)/out dir/x.lungfishprimeranalysis", "--blast-database=\(rootA.path)",
            "--assay=pcr",
        ])
        XCTAssertEqual(
            try RouteParityHarness.rebased(joined, from: rootA, to: rootB),
            command([
                "--output=\(rootB.path)/out dir/x.lungfishprimeranalysis", "--blast-database=\(rootB.path)",
                "--assay=pcr",
            ])
        )
    }

    func testTheTwoWordSpellingStillMovesThePath() throws {
        let split = command(["--output", "\(rootA.path)/x.lungfishprimeranalysis", "--assay=pcr"])
        XCTAssertEqual(
            try RouteParityHarness.rebased(split, from: rootA, to: rootB),
            command(["--output", "\(rootB.path)/x.lungfishprimeranalysis", "--assay=pcr"])
        )
    }

    func testAWordThatNamesTheRootAnywhereElseStillThrows() {
        let elsewhere = [
            // The value names root A after its start.
            "--note=see \(rootA.path)/x",
            // Only the first `=` splits, so this value is `b=<root A>/x`.
            "--name=b=\(rootA.path)/x",
            // A short option and a bare `name=value` word are not split.
            "-o=\(rootA.path)/x",
            "output=\(rootA.path)/x",
            // A value that ends with root A's name.
            "--parent=/elsewhere\(rootA.path)",
        ]
        for word in elsewhere {
            let line = command(["--output", "\(rootA.path)/x", word])
            XCTAssertThrowsError(try RouteParityHarness.rebased(line, from: rootA, to: rootB), word) { error in
                guard case RouteParityHarness.ReplayError.argumentOutsideRoot(let argument, _)? =
                    error as? RouteParityHarness.ReplayError
                else { return XCTFail("\(word): \(error)") }
                XCTAssertEqual(argument, word)
            }
        }
    }

    func testACommandWhoseOnlyPathIsInALongOptionWordIsRebased() throws {
        let joined = command(["--output=\(rootA.path)/x"])
        XCTAssertEqual(try RouteParityHarness.rebased(joined, from: rootA, to: rootB), command(["--output=\(rootB.path)/x"]))
        // A value outside both roots is left as written and still counts as nothing rebased.
        XCTAssertThrowsError(try RouteParityHarness.rebased(command(["--output=/elsewhere/x"]), from: rootA, to: rootB)) {
            XCTAssertEqual($0 as? RouteParityHarness.ReplayError, .nothingRebased(root: self.rootA.path))
        }
    }
}
