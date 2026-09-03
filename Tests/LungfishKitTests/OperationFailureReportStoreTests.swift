// OperationFailureReportStoreTests.swift - Automatic on-disk failure reports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishKit

@MainActor
final class OperationFailureReportStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("op-failure-reports-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Composition

    func testReportContainsCommandErrorDetailAndLog() {
        var item = OperationCenter.Item(
            title: "miSeq amplicon MHC genotyping",
            detail: "Failed",
            progress: 1,
            state: .failed,
            operationType: .classification,
            cliCommand: "lungfish-cli fastq genotype --output-dir '/tmp/results'",
            errorMessage: "miSeq amplicon MHC genotyping failed",
            errorDetail: "lungfish-cli exited with exit code 1.\nstderr:\nError: Run lock parent contains a symbolic link"
        )
        item.logEntries = [
            OperationLogEntry(level: .info, message: "Launching lungfish-cli..."),
            OperationLogEntry(level: .error, message: "failed with exit code 1"),
        ]

        let report = OperationFailureReportStore.buildFailureReport(for: item)

        XCTAssertTrue(report.hasPrefix("=== Lungfish Operation Failure Report ==="))
        XCTAssertTrue(report.contains("Operation: miSeq amplicon MHC genotyping"))
        XCTAssertTrue(report.contains("CLI Command:"))
        XCTAssertTrue(report.contains("lungfish-cli fastq genotype"))
        XCTAssertTrue(report.contains("Error: miSeq amplicon MHC genotyping failed"))
        XCTAssertTrue(report.contains("Details:"))
        XCTAssertTrue(report.contains("Run lock parent contains a symbolic link"))
        XCTAssertTrue(report.contains("Log:"))
        XCTAssertTrue(report.contains("failed with exit code 1"))
    }

    /// Download and ingestion paths only populate `detail`, so the report must
    /// still name a failure reason rather than emitting an empty Error line.
    func testReportFallsBackToDetailWhenNoStructuredErrorMessage() {
        let item = OperationCenter.Item(
            title: "Download",
            detail: "Server returned HTTP 503",
            progress: 1,
            state: .failed
        )

        let report = OperationFailureReportStore.buildFailureReport(for: item)

        XCTAssertTrue(report.contains("Error: Server returned HTTP 503"))
    }

    // MARK: - Writing

    func testWriteCreatesSortableTimestampedFileContainingTheReport() throws {
        let store = OperationFailureReportStore(directory: directory)
        var item = OperationCenter.Item(
            title: "Viral Recon",
            detail: "Failed",
            progress: 1,
            state: .failed,
            startedAt: Date(timeIntervalSince1970: 1_756_000_000),
            errorMessage: "nextflow exited with code 1"
        )
        item.logEntries = [OperationLogEntry(level: .error, message: "boom")]

        let url = try XCTUnwrap(store.writeReport(for: item))

        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(url.pathExtension, "log")
        XCTAssertTrue(
            url.lastPathComponent.contains("viral-recon"),
            "Expected a title slug in \(url.lastPathComponent)"
        )
        // A leading yyyyMMdd-HHmmss stamp keeps lexical order equal to time order.
        XCTAssertNotNil(
            url.lastPathComponent.range(of: #"^\d{8}-\d{6}-"#, options: .regularExpression),
            "Expected a sortable timestamp prefix in \(url.lastPathComponent)"
        )

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("=== Lungfish Operation Failure Report ==="))
        XCTAssertTrue(contents.contains("nextflow exited with code 1"))
    }

    func testWriteOnlyRecordsFailedOperations() throws {
        let store = OperationFailureReportStore(directory: directory)
        let completed = OperationCenter.Item(
            title: "Download",
            detail: "Done",
            progress: 1,
            state: .completed
        )

        XCTAssertNil(store.writeReport(for: completed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// Logging must never escalate an operation failure into a second failure,
    /// so an unwritable directory returns nil rather than throwing.
    func testWriteFailureIsSwallowed() throws {
        // A regular file where the directory should be makes createDirectory fail.
        let blocked = directory.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: blocked)

        let store = OperationFailureReportStore(directory: blocked)
        let item = OperationCenter.Item(
            title: "Assembly",
            detail: "Failed",
            progress: 1,
            state: .failed,
            errorMessage: "spades crashed"
        )

        XCTAssertNil(store.writeReport(for: item))
    }

    // MARK: - Retention

    func testWritePrunesOldestReportsBeyondTheRetentionLimit() throws {
        let store = OperationFailureReportStore(directory: directory, retentionLimit: 3)

        // Distinct start times so both the file names and the prune order are stable.
        for offset in 0..<5 {
            let item = OperationCenter.Item(
                title: "Run \(offset)",
                detail: "Failed",
                progress: 1,
                state: .failed,
                startedAt: Date(timeIntervalSince1970: 1_756_000_000 + Double(offset * 60)),
                errorMessage: "failure \(offset)"
            )
            XCTAssertNotNil(store.writeReport(for: item))
        }

        let remaining = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".log") }
            .sorted()

        XCTAssertEqual(remaining.count, 3)
        XCTAssertTrue(remaining.contains { $0.contains("run-2") })
        XCTAssertTrue(remaining.contains { $0.contains("run-4") })
        XCTAssertFalse(remaining.contains { $0.contains("run-0") })
        XCTAssertFalse(remaining.contains { $0.contains("run-1") })
    }

    func testPruningIgnoresUnrelatedFiles() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keeper = directory.appendingPathComponent("notes.txt")
        try "keep me".write(to: keeper, atomically: true, encoding: .utf8)

        let store = OperationFailureReportStore(directory: directory, retentionLimit: 1)
        for offset in 0..<3 {
            let item = OperationCenter.Item(
                title: "Run \(offset)",
                detail: "Failed",
                progress: 1,
                state: .failed,
                startedAt: Date(timeIntervalSince1970: 1_756_000_000 + Double(offset * 60)),
                errorMessage: "failure"
            )
            _ = store.writeReport(for: item)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: keeper.path))
    }

    // MARK: - Default location

    func testDefaultDirectoryFollowsTheAppIdentityLogsConvention() {
        let library = URL(fileURLWithPath: "/tmp/Library", isDirectory: true)

        XCTAssertEqual(
            OperationFailureReportStore.defaultDirectory(appIdentity: .stable, libraryDirectory: library),
            library.appendingPathComponent("Logs/Lungfish/Operations/Failures", isDirectory: true)
        )
        XCTAssertEqual(
            OperationFailureReportStore.defaultDirectory(appIdentity: .debug, libraryDirectory: library),
            library.appendingPathComponent("Logs/Lungfish Debug/Operations/Failures", isDirectory: true)
        )
    }

    /// The shared center is used by hundreds of tests that fail operations on
    /// purpose; those must never land in the developer's real logs directory.
    func testDefaultDirectoryIsRedirectedToTempUnderXCTest() {
        let directory = OperationFailureReportStore.defaultDirectory()

        XCTAssertTrue(
            directory.path.hasPrefix(NSTemporaryDirectory()),
            "Expected a temporary directory under test, got \(directory.path)"
        )
        XCTAssertFalse(directory.path.contains(FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Logs"))
    }

    // MARK: - OperationCenter integration

    func testFailingAnOperationWritesAReportWithoutOpeningThePanel() throws {
        let center = OperationCenter()
        center.failureReportStore = OperationFailureReportStore(directory: directory)

        let id = center.start(title: "Variant Calling", detail: "Running", operationType: .variantCalling)
        center.log(id: id, level: .info, message: "invoking bcftools")
        center.fail(
            id: id,
            detail: "Variant calling failed",
            errorMessage: "bcftools exited with code 2",
            errorDetail: "stderr: no such reference"
        )

        let item = try XCTUnwrap(center.items.first { $0.id == id })
        let url = try XCTUnwrap(item.failureReportURL, "fail() should record where the report landed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("Operation: Variant Calling"))
        XCTAssertTrue(contents.contains("bcftools exited with code 2"))
        XCTAssertTrue(contents.contains("no such reference"))
        XCTAssertTrue(contents.contains("invoking bcftools"))
    }

    /// A bundle-contention rejection is a recoverable "try again in a moment"
    /// message, not a diagnostic failure, so it deliberately does not consume
    /// the retention budget.
    func testBundleBusyRejectionDoesNotWriteAReport() throws {
        let center = OperationCenter()
        center.failureReportStore = OperationFailureReportStore(directory: directory)
        let bundleURL = URL(fileURLWithPath: "/tmp/busy-\(UUID().uuidString).lungfishref", isDirectory: true)

        _ = center.start(title: "Import A", detail: "Running", targetBundleURL: bundleURL)
        let blockedID = center.start(title: "Import B", detail: "Running", targetBundleURL: bundleURL)

        let blocked = try XCTUnwrap(center.items.first { $0.id == blockedID })
        XCTAssertEqual(blocked.state, .failed)
        XCTAssertNil(blocked.failureReportURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSuccessfulOperationsLeaveNoReport() {
        let center = OperationCenter()
        center.failureReportStore = OperationFailureReportStore(directory: directory)

        let id = center.start(title: "Export", detail: "Running", operationType: .export)
        center.complete(id: id, detail: "Done")

        XCTAssertNil(center.items.first { $0.id == id }?.failureReportURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
