// ViewerExportLeafTests.swift - The exits every viewer export leaf shares
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31, review 12.31-M3a Fix 4 (QA 4) and review 12.31-c5 Fix 3. `ViewerExportLeaf.run` exits 3 on a
// refusal, 64 on a failure and 125 on a cancel. EsVirituExportCLIGUIParityReplayTests also runs the cancel through
// the real transport.

import ArgumentParser
import XCTest
@testable import LungfishCLI

final class ViewerExportLeafTests: XCTestCase {
    func testARefusalExitsThree() async throws {
        let options = try GlobalOptions.parse([])
        do {
            try await ViewerExportLeaf.run(globalOptions: options, startMessage: "Testing a refusal.") { _ in
                throw ViewerExportRefusal("no")
            }
            XCTFail("a refusal ends the leaf with an exit")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit, CLIExitCode.inputError.exitCode)
        }
    }

    func testAFailureExitsSixtyFour() async throws {
        let options = try GlobalOptions.parse([])
        do {
            try await ViewerExportLeaf.run(globalOptions: options, startMessage: "Testing a failure.") { _ in
                throw CocoaError(.fileWriteUnknown)
            }
            XCTFail("a failure ends the leaf with an exit")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit, CLIExitCode.workflowError.exitCode)
        }
    }

    func testACancelExitsOneHundredTwentyFive() async throws {
        let options = try GlobalOptions.parse([])
        do {
            try await ViewerExportLeaf.run(globalOptions: options, startMessage: "Testing a cancel.") { _ in
                throw CancellationError()
            }
            XCTFail("a cancel ends the leaf with an exit")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit, CLIExitCode.cancelled.exitCode)
        }
    }
}
