// ViewerExportLeafTests.swift - The exits every viewer export leaf shares
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31, review 12.31-M3a Fix 4 (QA 4). `ViewerExportLeaf.run` exits 3 on a refusal and 64 on a
// failure. EsVirituExportCLIGUIParityReplayTests runs its cancel, exit 125, through the real transport.

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
}
