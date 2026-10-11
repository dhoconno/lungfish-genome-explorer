// ProvenanceRecorderSaveBytePinTests.swift - Byte captures of what ProvenanceRecorder.save writes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 2.7 lane S3 (scope row B2). The bytes `ProvenanceRecorder.save` writes for eight runs,
/// captured on the recorder as it stood before its rebuild on `ProvenanceRunBuilder`, in
/// `Tests/Fixtures/provenance-recorder`. The rebuild reproduces every capture byte for byte.
///
/// A capture masks what differs from one Mac or one test run to the next: run and step ids as
/// `<id-1>`, `<id-2>` and so on in order of first appearance, the scenario's temporary folder as
/// `<tmp>`, and the writing process's app version, executable, operating system, architecture,
/// dependency set and lock hash. Dates and wall times come from a stepped clock and stay in.
///
/// To capture a scenario again, delete its file and run this class with
/// `LUNGFISH_CAPTURE_RECORDER_PINS=1`. A capture never overwrites a file.
final class ProvenanceRecorderSaveBytePinTests: XCTestCase {
    private typealias Scenarios = ProvenanceRecorderSavePinScenarios

    func testACompletedRunSavedWithOptionsAndDroppedFilesKeepsItsBytes() async throws {
        try await assertCapture("completed-with-options") { try await Scenarios.completedRunWithOptions(in: $0) }
    }

    func testAFailedRunWithANonzeroStepKeepsItsBytes() async throws {
        try await assertCapture("failed-nonzero-step") { try await Scenarios.failedRunWithANonzeroStep(in: $0) }
    }

    func testACancelledRunWhoseLastStepExitedZeroKeepsItsBytes() async throws {
        try await assertCapture("cancelled-after-exit-zero") { try await Scenarios.cancelledRunAfterAnExitZeroStep(in: $0) }
    }

    func testARunWithRepeatedFilePathsKeepsEveryRepeat() async throws {
        try await assertCapture("repeated-file-paths") { try await Scenarios.runWithRepeatedFilePaths(in: $0) }
        let directory = try TestTempDirectory.make(prefix: "recorder-pin-repeats")
        defer { TestTempDirectory.cleanup(directory) }
        // The bytes, because the envelope decoder drops repeats when it reads a record.
        let sidecar = try await Scenarios.runWithRepeatedFilePaths(in: directory)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        let paths = try XCTUnwrap(object["files"] as? [[String: Any]]).compactMap { $0["path"] as? String }
        XCTAssertEqual(paths.count, 10, "the run-level files keep the four repeated tables")
        XCTAssertEqual(Set(paths).count, 6)
    }

    func testARunWithAContainerizedFirstStepKeepsItsBytes() async throws {
        try await assertCapture("containerized-first-step") { try await Scenarios.runWithAContainerizedFirstStep(in: $0) }
    }

    func testARunWithAReadSetPlanInItsParametersKeepsItsBytes() async throws {
        try await assertCapture("read-set-plan-parameter") { try await Scenarios.runWithAReadSetPlan(in: $0) }
    }

    func testARunSavedWhileRunningWithABlankStepVersionKeepsItsBytes() async throws {
        try await assertCapture("running-blank-step-version") { try await Scenarios.runningRunWithABlankStepVersion(in: $0) }
    }

    func testAFailedRunWithoutStepsKeepsItsBytes() async throws {
        try await assertCapture("failed-without-steps") { try await Scenarios.failedRunWithoutSteps(in: $0) }
    }

    // MARK: - Capture

    private static let captureFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/provenance-recorder", isDirectory: true)

    private func assertCapture(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        scenario: (URL) async throws -> URL
    ) async throws {
        let directory = try TestTempDirectory.make(prefix: "recorder-pin")
        defer { TestTempDirectory.cleanup(directory) }
        let sidecar = try await scenario(directory)
        let masked = Self.masked(try Data(contentsOf: sidecar), temporaryFolder: directory)
        let captureURL = Self.captureFolder.appendingPathComponent("\(name).json")

        if ProcessInfo.processInfo.environment["LUNGFISH_CAPTURE_RECORDER_PINS"] == "1",
           !FileManager.default.fileExists(atPath: captureURL.path) {
            try FileManager.default.createDirectory(at: Self.captureFolder, withIntermediateDirectories: true)
            try Data((masked + "\n").utf8).write(to: captureURL)
            return
        }
        let captured = try String(contentsOf: captureURL, encoding: .utf8)
        let expected = captured.hasSuffix("\n") ? String(captured.dropLast()) : captured
        XCTAssertEqual(masked, expected, "the saved bytes of \(name) differ from the capture", file: file, line: line)
    }

    /// The saved bytes with what differs between Macs and test runs replaced, see the class comment.
    static func masked(_ bytes: Data, temporaryFolder: URL) -> String {
        var text = String(decoding: bytes, as: UTF8.self)
        // The resolved form first, because it ends with the unresolved one.
        for folder in [temporaryFolder.resolvingSymlinksInPath().path, temporaryFolder.path] {
            text = text.replacingOccurrences(of: folder, with: "<tmp>")
        }
        let writer = ProvenanceRuntimeIdentity()
        let machineFacts: [(String?, String)] = [
            (writer.appVersion, "<app-version>"),
            (writer.executablePath, "<executable>"),
            (writer.operatingSystemVersion, "<operating-system>"),
            (writer.architecture, "<architecture>"),
            (writer.dependencySet, "<dependency-set>"),
            (writer.managedToolLockSHA256, "<lock-sha256>"),
        ]
        for case let (value?, mask) in machineFacts {
            text = text.replacingOccurrences(of: "\"\(value)\"", with: "\"\(mask)\"")
        }
        return maskingIDs(in: text)
    }

    /// Each UUID as `<id-N>`, numbered by first appearance, so a reference such as `dependsOn` still
    /// names the step it named.
    private static func maskingIDs(in text: String) -> String {
        guard let pattern = try? NSRegularExpression(
            pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        ) else { return text }
        let source = text as NSString
        var numbers: [String: Int] = [:]
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let id = source.substring(with: match.range).uppercased()
            let number = numbers[id] ?? (numbers.count + 1)
            numbers[id] = number
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += "<id-\(number)>"
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }
}
