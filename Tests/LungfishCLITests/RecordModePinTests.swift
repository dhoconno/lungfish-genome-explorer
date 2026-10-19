// RecordModePinTests.swift - The modes lungfish-cli files read before lane 12.23 changes the record writer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.23 M1 (RECORD-MODE, QA 1), written with no Sources edit so each pin passes at the base and after
// the fix. A marker is private on purpose and keeps 0600 (SWIFT 6). A record that replaces another publishes through
// DurableReplace, which stages with 0o666 under the umask, so it reads 0644 like the records the app writes. The red
// cases of the lane are in RecordModeCLIWriterTests.

import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

/// Runs each test under umask 022 and reads the modes of the files a writer left.
class RecordModeTestCase: XCTestCase {
    var scratch: URL!
    private var previousUmask: mode_t = 0o022

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = try TestTempDirectory.make(prefix: "record-mode")
        previousUmask = umask(0o022)
    }

    override func tearDownWithError() throws {
        umask(previousUmask)
        if let scratch { TestTempDirectory.cleanup(scratch) }
        try super.tearDownWithError()
    }

    /// The permission bits of every regular file under `root`, by relative path.
    func modes(under root: URL) -> [String: mode_t] {
        var found: [String: mode_t] = [:]
        let base = root.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(atPath: base) else { return found }
        for case let name as String in walker {
            var information = stat()
            guard lstat(base + "/" + name, &information) == 0, information.st_mode & S_IFMT == S_IFREG else { continue }
            found[name] = information.st_mode & 0o777
        }
        return found
    }

    func octal(_ mode: mode_t) -> String {
        "0" + String(mode, radix: 8)
    }

    /// Fails once for each file under `root`, except those named in `skipped`, that does not read 0644.
    func assertEveryFileReads0644(
        under root: URL,
        except skipped: Set<String> = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let found = modes(under: root).filter { !skipped.contains($0.key) }
        XCTAssertFalse(found.isEmpty, "the writer left no file under \(root.lastPathComponent)", file: file, line: line)
        for (name, mode) in found.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(octal(mode), "0644", "\(name) under umask 022", file: file, line: line)
        }
    }

    /// One run the way the CLI records it, `recordSingleStepRun` into `folder` with an output file beside the record.
    func recordRun(into folder: URL, named name: String = "lungfish record-mode") async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("result.txt")
        try Data("result\n".utf8).write(to: output)
        _ = try await CLIProvenanceSupport.recordSingleStepRun(
            name: name,
            parameters: [:],
            toolName: name,
            toolVersion: "0",
            command: ["lungfish-cli", "record-mode"],
            inputs: [],
            outputs: [ProvenanceRecorder.fileRecord(url: output, format: .unknown, role: .output)],
            exitCode: 0,
            wallTime: 0,
            stderr: nil,
            status: .completed,
            outputDirectory: folder
        )
    }
}

final class RecordModePinTests: RecordModeTestCase {
    /// The temp origin marker is state, private on purpose, and keeps 0600 whatever the record writer does.
    func testATempOriginMarkerReadsPrivate() throws {
        let project = scratch.appendingPathComponent("Pin.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let directory = try ProjectTempDirectory.create(prefix: "pin-", in: project)
        let found = modes(under: directory)
        XCTAssertFalse(found.isEmpty, "the directory holds its marker")
        for (name, mode) in found.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(octal(mode), "0600", "\(name) is a marker, private on purpose")
        }
    }

    /// A record that replaces another publishes through DurableReplace, so it reads 0644 like the records the app
    /// writes. The fix leaves it as it is.
    func testARecordThatReplacesAnotherReadsLikeTheAppsRecords() async throws {
        let folder = scratch.appendingPathComponent("Rewrite", isDirectory: true)
        try await recordRun(into: folder)
        try await recordRun(into: folder)
        let found = modes(under: folder)
        XCTAssertEqual(
            found[ProvenanceWriter.provenanceFilename].map(octal), "0644",
            "the rewritten record, among \(found.mapValues(octal))"
        )
    }
}
