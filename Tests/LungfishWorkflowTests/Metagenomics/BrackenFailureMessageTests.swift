// BrackenFailureMessageTests.swift - The message of a failed Bracken run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishTestSupport

/// W4 of Phase 2.10 (U34). A failed Bracken run shows the last line it wrote, not the whole traceback or usage
/// block, and a scratch path in that line reads as the run's record keeps it. The run itself is in
/// `BrackenFailureMessagePipelineTests`.
final class BrackenFailureMessageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "bracken-failure-message")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// A report outside any project.
    private var plainReport: URL {
        root.appendingPathComponent("output/classification.kreport")
    }

    private func message(_ stderr: String, exitCode: Int32 = 1, report: URL? = nil) -> String {
        BrackenFailureMessage.text(stderr: stderr, exitCode: exitCode, reportURL: report ?? plainReport)
    }

    // MARK: - The line

    func testATracebackEndsOnItsExceptionLine() {
        let stderr = """
        Traceback (most recent call last):
          File "est_abundance.py", line 205, in <module>
            main()
        UnboundLocalError: local variable 'u_reads' referenced before assignment

        """
        XCTAssertEqual(message(stderr), "UnboundLocalError: local variable 'u_reads' referenced before assignment")
    }

    func testAnArgparseRefusalEndsOnItsErrorLine() {
        let stderr = """
        usage: est_abundance.py [-h] -i INPUT -k KMER_DISTR -o OUTPUT [-l {S,G,O,F,P,C,D}] [-t THRESH]
        est_abundance.py: error: argument -t/--thresh: expected one argument

        """
        XCTAssertEqual(message(stderr), "est_abundance.py: error: argument -t/--thresh: expected one argument")
    }

    func testOneLineIsKeptWithoutItsLineBreak() {
        XCTAssertEqual(message("synthetic bracken failure\n"), "synthetic bracken failure")
        XCTAssertEqual(message("synthetic bracken failure"), "synthetic bracken failure")
    }

    func testBlankLinesAfterTheLastLineAreIgnored() {
        XCTAssertEqual(message("first\nlast line\n\n   \n\t\n"), "last line")
    }

    func testIndentationAndWindowsLineEndingsAreTrimmed() {
        XCTAssertEqual(message("first\r\n  last line  \r\n"), "last line")
    }

    // MARK: - No line

    func testEmptyStderrWithStatus127SaysBrackenWasNotAvailable() {
        XCTAssertEqual(
            message("", exitCode: 127),
            "Bracken executable was not available in the managed environment."
        )
    }

    func testEmptyStderrWithAnotherStatusNamesTheStatus() {
        XCTAssertEqual(message("", exitCode: 42), "Bracken exited with status 42.")
    }

    func testStderrOfWhiteSpaceOnlyCountsAsEmpty() {
        XCTAssertEqual(message("\n  \n\t\n", exitCode: 3), "Bracken exited with status 3.")
        XCTAssertEqual(
            message(" \n", exitCode: 127),
            "Bracken executable was not available in the managed environment."
        )
    }

    func testAnyLineWinsOverStatus127() {
        XCTAssertEqual(message("bracken: executable not found\n", exitCode: 127), "bracken: executable not found")
    }

    // MARK: - The scratch path

    /// The scratch copy of the report, a folder under the system's temporary folder as the staging makes it.
    private func stagedReport() -> (path: String, folder: String) {
        let folder = "lungfish-bracken-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("classification.kreport")
        return (url.path, folder)
    }

    func testAScratchPathInsideAProjectReadsAsTheRecordKeepsIt() {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let report = project.appendingPathComponent("Analyses/classification-1/classification.kreport")
        let staged = stagedReport()
        let stderr = """
        Traceback (most recent call last):
        FileNotFoundError: [Errno 2] No such file or directory: '\(staged.path)'

        """

        XCTAssertEqual(
            message(stderr, report: report),
            "FileNotFoundError: [Errno 2] No such file or directory: '<workspace>/\(staged.folder)/classification.kreport'"
        )
    }

    func testAScratchPathOutsideAProjectIsKeptAsBrackenWroteIt() {
        let staged = stagedReport()
        let stderr = "FileNotFoundError: [Errno 2] No such file or directory: '\(staged.path)'\n"

        XCTAssertEqual(
            message(stderr),
            "FileNotFoundError: [Errno 2] No such file or directory: '\(staged.path)'"
        )
    }

    /// Only the line that is shown passes through the rewrite, so a path in an earlier line changes nothing.
    func testAPathInAnEarlierLineIsNotShown() {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let report = project.appendingPathComponent("Analyses/classification-1/classification.kreport")
        let staged = stagedReport()

        XCTAssertEqual(
            message("reading \(staged.path)\nexit\n", report: report),
            "exit"
        )
    }
}
