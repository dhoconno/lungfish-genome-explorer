// GenotypeExcelRunPythonPinTests.swift - What GenotypeExcelExportService.runPython does, before and after its move
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Pins of the renderer spawn of `GenotypeExcelExportService` (Phase 2.13 lane 13.10 M2 item 1). A stand-in
/// "python" shell script plays the renderer, so the bytes it writes, the words it says, the status it ends with
/// and a cancel are known. They hold at the base, where `runPython` ran a raw `Process`, and after the move onto
/// `ToolProcess.run` with `.descriptor` outputs, which keeps the writer-created descriptors of `stdout.json` and
/// `stderr.txt` (no reopening by path).
final class GenotypeExcelRunPythonPinTests: XCTestCase {
    private let timestamp = "2026-09-12T12:00:00Z"
    private var root: URL!

    private static let runtimeJSON = #"{"pythonExecutable":"/usr/bin/python3","pythonVersion":"3.12.0","openpyxlVersion":"3.1.5","platform":"stand-in","renderer":{"schemaVersion":1,"sheets":[{"name":"Calls","rowCount":2,"cellCount":4}]}}"#

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lge-runpython-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func standIn(_ body: String) throws -> URL {
        let url = root.appendingPathComponent("stand-in-python")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeSnapshot() throws -> GenotypeWorkbookPresentation.Snapshot {
        try GenotypeExcelSnapshotBuilder.capture(
            result: GenotypeTestFixtures.makeResult(calls: []),
            sidecar: .empty(generatedAt: timestamp), allProjection: nil, filteredProjection: nil,
            generatedAt: timestamp
        )
    }

    private func export(
        with python: URL, to output: URL
    ) async throws -> GenotypeExcelExportService.ExportResult {
        try await GenotypeExcelExportService(pythonExecutableURL: python).export(
            snapshot: try makeSnapshot(), outputURL: output, provenance: .init(toolVersion: "test", argv: ["test"])
        )
    }

    private func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return info.st_mode & 0o777
    }

    private func exportFolders() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("report.xlsx.export-") }
    }

    /// The workbook the renderer wrote is published byte for byte, the artifacts hold exactly what its streams
    /// carried, and the receipt records the argv that ran, its status and its words.
    func testTheRendererBytesStreamsArgvAndStatusReachThePublishedFilesAndReceipt() async throws {
        let log = root.appendingPathComponent("child.log")
        let python = try standIn(#"""
        { printf 'cwd=%s\n' "$(pwd)"; printf 'home=%s\n' "$HOME"; printf 'arg=%s\n' "$@"; } > '\#(log.path)'
        printf 'PK\003\004workbook\000\377bytes' > "$3"
        printf '%s\n' '\#(Self.runtimeJSON)'
        printf 'renderer warning\n' >&2
        """#)
        let output = root.appendingPathComponent("report.xlsx")
        let exported = try await export(with: python, to: output)

        let workbook = Data([0x50, 0x4B, 0x03, 0x04]) + Data("workbook".utf8) + Data([0x00, 0xFF]) + Data("bytes".utf8)
        XCTAssertEqual(try Data(contentsOf: output), workbook)
        let artifacts = exported.artifactDirectoryURL
        XCTAssertEqual(try Data(contentsOf: artifacts.appendingPathComponent("stdout.json")),
            Data((Self.runtimeJSON + "\n").utf8))
        XCTAssertEqual(try String(contentsOf: artifacts.appendingPathComponent("stderr.txt"), encoding: .utf8),
            "renderer warning\n")
        XCTAssertEqual(try mode(artifacts.appendingPathComponent("stdout.json")), 0o600)
        XCTAssertEqual(try mode(artifacts.appendingPathComponent("stderr.txt")), 0o600)

        let executed = exported.execution.executedArgv
        XCTAssertEqual(executed.count, 4)
        XCTAssertEqual(executed[0], python.standardizedFileURL.path)
        XCTAssertEqual(executed.dropFirst().map { URL(fileURLWithPath: $0).lastPathComponent },
            ["renderer.py", "snapshot.json", "rendered.xlsx"])
        XCTAssertEqual(URL(fileURLWithPath: executed[1]).deletingLastPathComponent().path,
            artifacts.standardizedFileURL.path)
        // What the child received is what was recorded, in the caller's folder and environment.
        let childLog = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(childLog.filter { $0.hasPrefix("arg=") }, executed.dropFirst().map { "arg=" + $0 })
        let childCwd = childLog.first { $0.hasPrefix("cwd=") }.map { String($0.dropFirst(4)) }
        XCTAssertEqual(childCwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path)
        let childHome = childLog.first { $0.hasPrefix("home=") }
        XCTAssertEqual(childHome, "home=" + (ProcessInfo.processInfo.environment["HOME"] ?? ""))

        XCTAssertEqual(exported.execution.stderr, "renderer warning\n")
        XCTAssertEqual(exported.execution.openpyxlVersion, "3.1.5")
        XCTAssertEqual(exported.execution.sheetNames, ["Calls"])
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: output.appendingPathExtension("provenance.json"))) as? [String: Any])
        XCTAssertEqual(receipt["exitStatus"] as? Int, 0)
        XCTAssertEqual(receipt["stderr"] as? String, "renderer warning\n")
        XCTAssertEqual(receipt["executedArgv"] as? [String], executed)
    }

    /// A renderer that logs 300 KB reaches `stderr.txt` and the receipt whole.
    func testALargeRendererStderrIsKeptWholeInTheArtifactAndTheReceipt() async throws {
        let python = try standIn(#"""
        printf 'PK' > "$3"
        printf '%s\n' '\#(Self.runtimeJSON)'
        head -c 300000 /dev/zero | tr '\000' 'e' >&2
        """#)
        let output = root.appendingPathComponent("report.xlsx")
        let exported = try await export(with: python, to: output)
        let stderrURL = exported.artifactDirectoryURL.appendingPathComponent("stderr.txt")
        XCTAssertEqual(try Data(contentsOf: stderrURL), Data(repeating: UInt8(ascii: "e"), count: 300_000))
        XCTAssertEqual(exported.execution.stderr.count, 300_000)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: output.appendingPathExtension("provenance.json"))) as? [String: Any])
        XCTAssertEqual((receipt["stderr"] as? String)?.count, 300_000)
    }

    /// A nonzero exit and a kill by a signal both fail the export with the raw status and the renderer's words,
    /// and publish and retain nothing.
    func testAFailingRendererThrowsItsStatusAndWordsAndLeavesNothingBehind() async throws {
        for (body, expectedStatus, expectedWords) in [
            ("printf 'boom: bad cell\\n' >&2\nexit 7", Int32(7), "boom: bad cell\n"),
            ("printf 'killed\\n' >&2\nkill -KILL $$", Int32(9), "killed\n"),
        ] {
            let python = try standIn(body)
            let output = root.appendingPathComponent("report.xlsx")
            do {
                _ = try await export(with: python, to: output)
                XCTFail("a failing renderer was accepted")
            } catch GenotypeExcelExportService.ExportError.rendererFailed(let status, let words) {
                XCTAssertEqual(status, expectedStatus)
                XCTAssertEqual(words, expectedWords)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathExtension("provenance.json").path))
            XCTAssertEqual(try exportFolders(), [])
        }
    }

    /// A cancel while the renderer runs stops it, throws `CancellationError`, keeps the previous report and its
    /// receipt, and removes the export's artifact folder.
    func testACancelStopsTheRendererThrowsCancellationAndLeavesNothingBehind() async throws {
        let pidFile = root.appendingPathComponent("renderer.pid")
        let python = try standIn(#"""
        printf '%s' "$$" > '\#(pidFile.path)'
        exec sleep 120
        """#)
        let output = root.appendingPathComponent("report.xlsx")
        let receipt = output.appendingPathExtension("provenance.json")
        let oldReport = Data("previous successful report".utf8)
        let oldReceipt = Data("previous successful receipt".utf8)
        try oldReport.write(to: output)
        try oldReceipt.write(to: receipt)
        let snapshot = try makeSnapshot()
        let task = Task {
            try await GenotypeExcelExportService(pythonExecutableURL: python).export(
                snapshot: snapshot, outputURL: output, provenance: .init(toolVersion: "test", argv: ["test"])
            )
        }
        var rendererPID: Int32?
        for _ in 0..<1500 where rendererPID == nil {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8) {
                rendererPID = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if rendererPID == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        let pid = try XCTUnwrap(rendererPID, "the renderer never started")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled export finished")
        } catch is CancellationError {
        } catch {
            XCTFail("a cancel threw \(error) and not CancellationError")
        }
        var gone = false
        for _ in 0..<1500 where !gone {
            gone = Darwin.kill(pid, 0) == -1 && errno == ESRCH
            if !gone { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertTrue(gone, "the renderer \(pid) still runs after the cancel")
        XCTAssertEqual(try Data(contentsOf: output), oldReport)
        XCTAssertEqual(try Data(contentsOf: receipt), oldReceipt)
        XCTAssertEqual(try exportFolders(), [])
    }
}
