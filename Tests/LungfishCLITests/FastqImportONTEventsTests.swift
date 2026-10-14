// FastqImportONTEventsTests.swift - `fastq import-ont --format json` speaks events with today's stage words
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A53 M2 (panel decisions C11, C5, UX 1). The ONT import runs on `lungfish-cli fastq
// import-ont`, so the leaf has to say what the window's row said when the import ran in the app. The row
// began with "Detecting layout...", then showed the workflow's stage words ("Detecting ONT directory
// layout...", "barcode01: Copying 2 chunks...", "Completed 2/2 barcodes", "Import complete (...)"), and
// ended "2 barcode bundles, 5 reads" with the bundles it made. These tests run the built `lungfish-cli`
// as a process, since the leaf is what the app launches, and read its standard output the way the
// transport does. They fail at the base, where the leaf takes no `--format` and prints no event.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class FastqImportONTEventsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "fastq-import-ont-events")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testTheLeafPrintsOnlyEventLinesWithTodaysStageWordsUnderFormatJSON() throws {
        let source = try makeSource()
        let output = root.appendingPathComponent("imported", isDirectory: true)

        let run = try runLeaf([source.path, "--output", output.path, "--concurrency", "1", "--format", "json"])

        XCTAssertEqual(run.status, 0, "stderr: \(run.stderr)")
        let lines = run.stdout.split(separator: "\n").map(String.init)
        XCTAssertFalse(lines.isEmpty, "the leaf printed no event, stderr: \(run.stderr)")
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("{") }, "standard output holds nothing but event lines: \(lines)")
        let events = try lines.map { try XCTUnwrap(CLIEventLineDecoder().decode(line: $0), $0) }

        XCTAssertEqual(events.first, .start(message: "Detecting layout..."), "the row's first detail is today's")
        let words = events.compactMap { event -> String? in
            if case let .progress(_, message) = event { return message }
            return nil
        }
        XCTAssertEqual(words.first, "Detecting ONT directory layout...")
        XCTAssertTrue(words.contains { $0.hasPrefix("barcode01: ") }, "a per-barcode word names its barcode: \(words)")
        XCTAssertTrue(words.contains { $0.hasPrefix("barcode02: ") }, "\(words)")
        XCTAssertTrue(words.contains("Completed 2/2 barcodes"), "\(words)")
        XCTAssertTrue(words.last?.hasPrefix("Import complete (5 reads, ") == true, "\(words)")

        let terminal = events.filter {
            switch $0 {
            case .complete, .failed: return true
            case .start, .progress, .log, .output: return false
            }
        }
        XCTAssertEqual(terminal.count, 1, "one terminal event")
        XCTAssertEqual(
            events.last,
            .complete(
                outputs: [
                    output.appendingPathComponent("barcode01.lungfishfastq").path,
                    output.appendingPathComponent("barcode02.lungfishfastq").path,
                ],
                message: "2 barcode bundles, 5 reads"
            ),
            "the bundles in barcode order, so the window opens the first, with the row's closing words"
        )
        let manifest = try XCTUnwrap(DemultiplexManifest.load(from: output))
        XCTAssertEqual(manifest.barcodes.map(\.readCount), [3, 2])
    }

    func testTheLeafKeepsStandardOutputEmptyWithoutAFormat() throws {
        let source = try makeSource()
        let output = root.appendingPathComponent("imported-text", isDirectory: true)

        let run = try runLeaf([source.path, "--output", output.path, "--concurrency", "1"])

        XCTAssertEqual(run.status, 0, "stderr: \(run.stderr)")
        XCTAssertEqual(run.stdout, "", "text mode prints its human lines on standard error, as before")
        XCTAssertTrue(run.stderr.contains("--- ONT Import Summary ---"), run.stderr)
        XCTAssertTrue(run.stderr.contains("Total reads: 5"), run.stderr)
    }

    func testAFailedRunEndsTheStreamWithOneFailedEventAndTheErrorStatus() throws {
        let folder = root.appendingPathComponent("not-an-ont-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("never-written", isDirectory: true)

        let run = try runLeaf([folder.path, "--output", output.path, "--format", "json"])

        XCTAssertNotEqual(run.status, 0)
        XCTAssertNotEqual(run.status, CLISIGTERMHarness.cancelledExitStatus, "a failure is not a cancel")
        let events = try run.stdout.split(separator: "\n").map {
            try XCTUnwrap(CLIEventLineDecoder().decode(line: String($0)), String($0))
        }
        XCTAssertEqual(events.first, .start(message: "Detecting layout..."))
        guard case let .failed(message, _)? = events.last else {
            return XCTFail("the stream does not end in a failed event: \(events)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(events.filter { if case .failed = $0 { return true } else { return false } }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a refused folder writes nothing")
    }

    // MARK: - Helpers

    private func runLeaf(_ arguments: [String]) throws -> ProcessResult {
        guard let cli = CLISIGTERMHarness.cliBinaryURL(for: Self.self) else {
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
        }
        return try ProcessRunner.run(
            cli,
            ["fastq", "import-ont"] + arguments,
            environment: CLISIGTERMHarness.childEnvironment(),
            timeout: 120
        )
    }

    /// barcode01 holds two chunks (2 and 1 reads) and barcode02 one chunk (2 reads).
    private func makeSource() throws -> URL {
        let source = root.appendingPathComponent("fastq_pass", isDirectory: true)
        func chunk(_ barcode: String, _ name: String, reads: [String]) throws {
            let directory = source.appendingPathComponent(barcode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let text = reads.map {
                "@\($0) runid=test flow_cell_id=FLO-MIN sample_id=S1 barcode=\(barcode) basecall_model_version_id=dorado-test\nACGTACGT\n+\nIIIIIIII\n"
            }.joined()
            try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try chunk("barcode01", "chunk_0.fastq", reads: ["r1", "r2"])
        try chunk("barcode01", "chunk_1.fastq", reads: ["r3"])
        try chunk("barcode02", "chunk_0.fastq", reads: ["r4", "r5"])
        return source
    }
}
