// ExtractOverlappingReadsFailureTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Regression coverage for F24: `extractOverlappingReads(from:)` used to swallow
// both errors and results silently (a `Task.detached` that only logged failures
// to os_log, with no OperationCenter registration and no user-visible alert).
// Since Phase 2.10 lane A51 (p48) the row runs the `lungfish-cli extract reads
// --by-region` command it records on the L3 runner, so these tests put a
// stand-in lungfish-cli on LUNGFISH_CLI_PATH that writes down its argv and
// plays a failure or a completion, and assert the OperationCenter row and the
// failure alert on both paths.

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishKit
@testable import LungfishWorkflow
import LungfishKitTestSupport

@MainActor
final class ExtractOverlappingReadsFailureTests: XCTestCase {
    private var resultDirectory: URL!
    private var priorCLIPath: String?

    override func setUp() async throws {
        try await super.setUp()
        OperationCenter.useTemporaryFailureReportsForTesting()
        resultDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-overlapping-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
        priorCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
    }

    override func tearDown() async throws {
        if let priorCLIPath {
            setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1)
        } else {
            unsetenv("LUNGFISH_CLI_PATH")
        }
        if let resultDirectory { try? FileManager.default.removeItem(at: resultDirectory) }
        try await super.tearDown()
    }

    /// Records failure-alert presentations. `@MainActor` because the injected
    /// `extractionFailureAlertPresenter` is `@MainActor` and only touched there.
    @MainActor
    private final class AlertRecorder {
        private(set) var presentations: [(title: String, message: String)] = []

        func record(title: String, message: String) {
            presentations.append((title, message))
        }
    }

    /// An annotation whose extraction has a valid, non-empty samtools region,
    /// `chr1:11-50`, so `extractOverlappingReads` doesn't bail out early on
    /// `mappingExtractionConfiguration(for:) == nil`.
    private func makeAnnotation() -> SequenceAnnotation {
        SequenceAnnotation(
            type: .gene,
            name: "test-gene",
            chromosome: "chr1",
            start: 10,
            end: 50
        )
    }

    /// A viewer showing a mapping result in the test's folder, whose failure alerts go to
    /// `alerts`. A failure never presents a live `NSAlert`: a real `beginSheetModal` or
    /// `presentError` blocks indefinitely under an attached WindowServer (an interactive
    /// session), which hangs the test.
    private func makeViewer(alerts: AlertRecorder) -> ViewerViewController {
        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: resultDirectory.appendingPathComponent("reference.lungfishref", isDirectory: true),
            bamURL: resultDirectory.appendingPathComponent("sample.sorted.bam"),
            baiURL: resultDirectory.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 10,
            mappedReads: 9,
            unmappedReads: 1,
            wallClockSeconds: 1.0,
            contigs: []
        )
        let vc = ViewerViewController()
        vc.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        vc.displayMappingResult(result, resultDirectoryURL: resultDirectory)
        vc.extractionFailureAlertPresenter = { title, message in
            alerts.record(title: title, message: message)
        }
        return vc
    }

    /// Puts a stand-in lungfish-cli on LUNGFISH_CLI_PATH that writes its argv,
    /// one word a line, to the returned file, prints `events` and exits with
    /// `status`.
    private func useStandInCLI(events: [String], status: Int32) throws -> URL {
        let cli = resultDirectory.appendingPathComponent("lungfish-cli")
        let argvFile = resultDirectory.appendingPathComponent("argv.txt")
        let printing = events.map { "echo '\($0)'" }.joined(separator: "\n")
        try """
        #!/bin/sh
        for word in "$@"; do echo "$word" >> '\(argvFile.path)'; done
        \(printing)
        exit \(status)
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        return argvFile
    }

    private static let startEvent = #"{"event":"start","message":"Extracting reads…","progress":0,"schemaVersion":2}"#

    /// Polls until `predicate()` is true or the timeout elapses.
    private func eventually(
        timeout: TimeInterval = 30,
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    /// The first row titled Extract Overlapping Reads that was not in `before`, once it is `state`.
    private func row(after before: Set<UUID>, reaching state: OperationCenter.Item.State) async throws -> OperationCenter.Item {
        let reached = await eventually {
            OperationCenter.shared.items.contains { !before.contains($0.id) && $0.title == "Extract Overlapping Reads" && $0.state == state }
        }
        XCTAssertTrue(reached, "Expected an Extract Overlapping Reads row that is \(state)")
        return try XCTUnwrap(OperationCenter.shared.items.first { !before.contains($0.id) && $0.title == "Extract Overlapping Reads" })
    }

    func testFailingExtractionFailsOperationAndPresentsAlertInsteadOfSilentlyLogging() async throws {
        let argvFile = try useStandInCLI(events: [
            Self.startEvent,
            #"{"error":"stub samtools failure: region not found","event":"failed","schemaVersion":2}"#,
        ], status: 1)
        let alertRecorder = AlertRecorder()
        let vc = makeViewer(alerts: alertRecorder)
        let before = Set(OperationCenter.shared.items.map(\.id))

        vc.extractOverlappingReads(from: makeAnnotation())

        let failedItem = try await row(after: before, reaching: .failed)
        XCTAssertEqual(failedItem.state, .failed)
        XCTAssertEqual(failedItem.errorMessage, "stub samtools failure: region not found")
        // The row ran the command it records, for the annotation's region,
        // which proves the failure came through the real call site.
        let argv = try String(contentsOf: argvFile, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(argv, try RecordedCLICommand.arguments(of: failedItem.cliCommand))
        XCTAssertTrue(argv.contains("chr1:11-50"), "\(argv)")
        // The failure surfaced to the user through the alert, not just the log.
        let alerted = await eventually { !alertRecorder.presentations.isEmpty }
        XCTAssertTrue(alerted)
        XCTAssertEqual(alertRecorder.presentations.count, 1)
        XCTAssertEqual(alertRecorder.presentations.first?.title, "Extract Overlapping Reads Failed")
        XCTAssertEqual(alertRecorder.presentations.first?.message, "stub samtools failure: region not found")
    }

    func testSuccessfulExtractionCompletesOperationWithOutputURLs() async throws {
        let outputFASTQ = resultDirectory.appendingPathComponent("test-gene.fastq")
        _ = try useStandInCLI(events: [
            Self.startEvent,
            #"{"event":"complete","message":"Extracted 42 reads","outputs":["\#(outputFASTQ.path)"],"progress":1,"schemaVersion":2}"#,
        ], status: 0)
        let alertRecorder = AlertRecorder()
        let vc = makeViewer(alerts: alertRecorder)
        let before = Set(OperationCenter.shared.items.map(\.id))

        vc.extractOverlappingReads(from: makeAnnotation())

        let completedItem = try await row(after: before, reaching: .completed)
        XCTAssertEqual(completedItem.outputURLs, [outputFASTQ])
        XCTAssertEqual(completedItem.detail, "Extracted 42 reads overlapping test-gene")
        XCTAssertTrue(alertRecorder.presentations.isEmpty, "a completed row presents no alert")
    }
}
