// ImportBAMPlainFolderEventsTests.swift - `import bam` into a plain folder prints the row's events with --format json
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.06 (A63-M3 M2, A63 review note 4). Phase 2.11 gave `import bam` events only for an output
// that is an existing `.lungfishref` bundle, so a plain output folder printed its text summary on standard
// output even with `--format json`. These cases run the built `lungfish-cli` into a plain folder with a
// storage root that holds no managed samtools, so the leaf copies the BAM and its index, warns that it
// skipped the statistics, records the run, and needs no real tool.

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishCLI

final class ImportBAMPlainFolderEventsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-bam-plain-events")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testAPlainFolderImportPrintsOnlyEventsAndCompletesWithTheCopiedFile() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sarscov2/test.paired_end.sorted.bam")
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let input = inputs.appendingPathComponent("sample.bam")
        try FileManager.default.copyItem(at: fixture, to: input)
        try FileManager.default.copyItem(at: fixture.appendingPathExtension("bai"), to: input.appendingPathExtension("bai"))
        let folder = root.appendingPathComponent("plain", isDirectory: true)

        let result = try runCLI(["import", "bam", input.path, "--output-dir", folder.path, "--format", "json"])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let events = try Self.events(in: result.stdout)
        XCTAssertEqual(events.first?["event"] as? String, "start", "\(events)")
        XCTAssertEqual(events.last?["event"] as? String, "complete", "\(events)")
        let copied = folder.appendingPathComponent("sample.bam")
        XCTAssertEqual(events.last?["outputs"] as? [String], [copied.path], "\(events)")
        XCTAssertTrue(events.contains { $0["event"] as? String == "progress" }, "the row sees progress: \(events)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path), "the BAM was copied")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.appendingPathExtension("bai").path), "and its index")
        XCTAssertTrue(result.stderr.contains("BAM import complete"), "the summary goes to standard error: \(result.stderr)")
    }

    func testAPlainFolderRefusalEndsWithAFailedEvent() throws {
        let input = root.appendingPathComponent("notes.txt")
        try Data("not an alignment\n".utf8).write(to: input)
        let folder = root.appendingPathComponent("plain", isDirectory: true)

        let result = try runCLI(["import", "bam", input.path, "--output-dir", folder.path, "--format", "json"])

        XCTAssertEqual(result.exitCode, CLIExitCode.formatError.rawValue, result.stderr)
        let events = try Self.events(in: result.stdout)
        XCTAssertEqual(events.map { $0["event"] as? String }, ["start", "failed"], "\(events)")
        XCTAssertTrue((events.last?["error"] as? String)?.contains("Unsupported alignment format") == true, "\(events)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "a refusal makes no folder")
    }

    // MARK: - Helpers

    /// Every line of standard output as an event, failing on a line that is not one.
    private static func events(in stdout: String, file: StaticString = #filePath, line: UInt = #line) throws -> [[String: Any]] {
        try stdout.split(separator: "\n").map { text in
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            return try XCTUnwrap(object, "standard output holds only events, not \(text)", file: file, line: line)
        }
    }

    /// Runs the built `lungfish-cli` with a storage root and a conda root that hold no tool, and waits up to a minute.
    private func runCLI(_ arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let binary = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(
                buildProductsDirectory: Bundle(for: ImportBAMPlainFolderEventsTests.self).bundleURL.deletingLastPathComponent()
            ),
            "Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle"
        )
        let storage = root.appendingPathComponent("storage", isDirectory: true)
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = CLISIGTERMHarness.childEnvironment(overriding: [
            "LUNGFISH_STORAGE_ROOT": storage.path,
            "LUNGFISH_CONDA_ROOT": storage.appendingPathComponent("conda", isDirectory: true).path,
        ])
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            if process.isRunning { process.terminate() }
        }
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}
