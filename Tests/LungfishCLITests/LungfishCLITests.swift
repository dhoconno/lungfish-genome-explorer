// LungfishCLITests.swift - Tests for CLI commands
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI

final class LungfishCLITests: XCTestCase {

    // MARK: - Global Options Tests

    func testGlobalOptionsDefaults() {
        let options = GlobalOptions()
        XCTAssertNil(options.output)
        XCTAssertEqual(options.outputFormat, .text)
        XCTAssertEqual(options.verbosity, 0)
        XCTAssertFalse(options.quiet)
        XCTAssertFalse(options.debug)
    }

    func testEffectiveVerbosityQuiet() {
        var options = GlobalOptions()
        options.quiet = true
        XCTAssertEqual(options.effectiveVerbosity, -1)
    }

    func testOutputModeJSON() {
        var options = GlobalOptions()
        options.outputFormat = .json
        XCTAssertEqual(options.outputMode, .json)
    }

    func testOutputModeDebug() {
        var options = GlobalOptions()
        options.debug = true
        XCTAssertEqual(options.outputMode, .debug)
    }

    // MARK: - Terminal Formatter Tests

    func testTerminalFormatterColors() {
        let formatter = TerminalFormatter(useColors: true)
        let colored = formatter.colored("test", .red)
        XCTAssertTrue(colored.contains("\u{001B}[31m"))
        XCTAssertTrue(colored.contains("test"))
    }

    func testTerminalFormatterNoColors() {
        let formatter = TerminalFormatter(useColors: false)
        let text = formatter.colored("test", .red)
        XCTAssertEqual(text, "test")
        XCTAssertFalse(text.contains("\u{001B}"))
    }

    func testProgressBar() {
        let formatter = TerminalFormatter(useColors: false)
        let bar = formatter.progressBar(progress: 0.5, width: 10)
        XCTAssertTrue(bar.contains("50%"))
    }

    func testStripANSI() {
        let text = "\u{001B}[31mRed\u{001B}[0m text"
        let stripped = TerminalFormatter.stripANSI(text)
        XCTAssertEqual(stripped, "Red text")
    }

    func testKeyValueTable() {
        let formatter = TerminalFormatter(useColors: false)
        let table = formatter.keyValueTable([
            ("Key1", "Value1"),
            ("Key2", "Value2"),
        ])
        XCTAssertTrue(table.contains("Key1"))
        XCTAssertTrue(table.contains("Value1"))
    }

    // MARK: - Exit Code Tests

    func testExitCodes() {
        XCTAssertEqual(CLIExitCode.success.rawValue, 0)
        XCTAssertEqual(CLIExitCode.failure.rawValue, 1)
        XCTAssertEqual(CLIExitCode.inputError.rawValue, 3)
        XCTAssertEqual(CLIExitCode.workflowError.rawValue, 64)
        XCTAssertEqual(CLIExitCode.containerError.rawValue, 65)
    }

    // MARK: - CLI Error Tests

    func testCLIErrorDescriptions() {
        let error1 = CLIError.inputFileNotFound(path: "/test/path")
        XCTAssertTrue(error1.localizedDescription.contains("/test/path"))

        let error2 = CLIError.containerUnavailable
        XCTAssertTrue(error2.localizedDescription.contains("macOS 26"))

        let error3 = CLIError.unsupportedFormat(format: "xyz")
        XCTAssertTrue(error3.localizedDescription.contains("xyz"))
    }

    func testCLIErrorExitCodes() {
        XCTAssertEqual(CLIError.inputFileNotFound(path: "").exitCode, .inputError)
        XCTAssertEqual(CLIError.outputWriteFailed(path: "", reason: "").exitCode, .outputError)
        XCTAssertEqual(CLIError.workflowFailed(reason: "").exitCode, .workflowError)
        XCTAssertEqual(CLIError.containerUnavailable.exitCode, .containerError)
        XCTAssertEqual(CLIError.networkError(reason: "").exitCode, .networkError)
    }
}

// MARK: - Output Handler Tests

final class OutputHandlerTests: XCTestCase {

    func testJSONOutputHandler() {
        let handler = JSONOutputHandler()

        struct TestData: Codable {
            let value: Int
        }

        // Should not throw
        handler.writeData(TestData(value: 42), label: nil)
    }

    func testTSVOutputHandler() {
        let handler = TSVOutputHandler()
        handler.setHeaders(["Col1", "Col2"])
        handler.addRow(["Val1", "Val2"])
        // Should not throw
        handler.finish()
    }
}
