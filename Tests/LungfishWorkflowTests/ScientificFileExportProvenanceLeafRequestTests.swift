// ScientificFileExportProvenanceLeafRequestTests.swift - The record a lungfish-cli export leaf writes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M2 (ARCH ruling X-3 and 1.4). A leaf's request names the tool `lungfish-cli` with kind `cli`
// and replays its own canonical argv. The two existing inits take the tool and the kind from their caller (ruling 4.1).

import Foundation
import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class ScientificFileExportProvenanceLeafRequestTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportLeafRequest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testALeafRequestRecordsTheCLIToolKindAndItsOwnArgv() throws {
        let source = folder.appendingPathComponent("source.json")
        try Data("{}".utf8).write(to: source)
        let output = folder.appendingPathComponent("table.tsv")
        let argv = [CLICommandIdentity.executableName, "esviritu", "export", "detections", folder.path, "-o", output.path]
        let request = ScientificFileExportProvenance.Request.cliLeaf(
            workflowName: "lungfish esviritu export detections",
            sourceURLs: [source],
            outputURL: output,
            outputFormat: .text,
            argv: argv,
            resolved: ["rowCount": .integer(1)],
            runClock: ProvenanceRunClock()
        )
        XCTAssertEqual(request.toolName, "lungfish-cli")
        XCTAssertEqual(request.toolKind, "cli")
        XCTAssertNil(request.durableReplayArgv)

        let sidecar = try ScientificFileExportProvenance.writeAtomically(request) { staged in
            try Data("a\tb\n".utf8).write(to: staged)
        }

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        XCTAssertEqual(envelope.toolName, "lungfish-cli")
        XCTAssertEqual(envelope.tool.name, "lungfish-cli")
        XCTAssertEqual(envelope.tool.kind, "cli")
        XCTAssertEqual(envelope.argv, argv)
        XCTAssertEqual(envelope.durableReplayArgv, argv)
        XCTAssertEqual(envelope.workflowName, "lungfish esviritu export detections")
        XCTAssertEqual(envelope.files.filter { $0.role == .input }.map(\.path), [source.standardizedFileURL.path])
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "a\tb\n")
    }

    func testTheExistingInitsRecordTheToolAndKindTheirCallerNamesAndTheReplacedRequestKeepsItsKind() {
        let output = folder.appendingPathComponent("table.tsv")
        let gui = ScientificFileExportProvenance.Request(
            workflowName: "w", toolName: "Lungfish.app", toolKind: "gui", sourceURLs: [], outputURL: output,
            outputFormat: .text, argv: ["Lungfish.app"], runClock: ProvenanceRunClock()
        )
        XCTAssertEqual(gui.toolName, "Lungfish.app")
        XCTAssertEqual(gui.toolKind, "gui")
        let cli = ScientificFileExportProvenance.Request(
            workflowName: "w", toolName: "lungfish-cli", toolKind: "cli", sourceURLs: [], outputURL: output,
            outputFormat: .text, argv: ["lungfish-cli"], startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(cli.toolName, "lungfish-cli")
        XCTAssertEqual(cli.toolKind, "cli")
        let leaf = ScientificFileExportProvenance.Request.cliLeaf(
            workflowName: "w", sourceURLs: [], outputURL: output, outputFormat: .text,
            argv: ["lungfish-cli"], runClock: ProvenanceRunClock()
        )
        XCTAssertEqual(leaf.replacing(sourceURLs: [], durableReplayArgv: nil, resolved: [:]).toolKind, "cli")
    }
}
