// UniversalSearchCommandTests.swift - Parsing and registration tests for universal-search CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
import LungfishWorkflow
@testable import LungfishCLI

final class UniversalSearchCommandTests: XCTestCase {

    func testUniversalSearchParsingDefaults() throws {
        let cmd = try UniversalSearchCommand.parse([
            "/tmp/project.lungfish",
        ])

        XCTAssertEqual(cmd.projectPath, "/tmp/project.lungfish")
        XCTAssertEqual(cmd.query, "")
        XCTAssertEqual(cmd.limit, 200)
        XCTAssertFalse(cmd.reindex)
        XCTAssertFalse(cmd.stats)
    }

    func testUniversalSearchParsingCustomOptions() throws {
        let cmd = try UniversalSearchCommand.parse([
            "/tmp/project.lungfish",
            "--query", "virus:hku1 type:classification_result",
            "--limit", "75",
            "--reindex",
            "--stats",
        ])

        XCTAssertEqual(cmd.projectPath, "/tmp/project.lungfish")
        XCTAssertEqual(cmd.query, "virus:hku1 type:classification_result")
        XCTAssertEqual(cmd.limit, 75)
        XCTAssertTrue(cmd.reindex)
        XCTAssertTrue(cmd.stats)
    }

    func testUniversalSearchRegisteredAtRoot() {
        let subcommands = LungfishCLI.configuration.subcommands
        let names = subcommands.map { $0.configuration.commandName }

        XCTAssertTrue(
            names.contains("universal-search"),
            "LungfishCLI should include universal-search subcommand"
        )
    }

    func testUniversalSearchReindexWritesIndexProvenanceSidecar() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniversalSearchCommandTests-\(UUID().uuidString).lungfish", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try #"{"sample_name":"Air Sample 01","collection_date":"2026-03-01"}"#
            .write(to: projectURL.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let command = try UniversalSearchCommand.parse([
            projectURL.path,
            "--query", "sample:air",
            "--reindex",
            "--quiet",
        ])
        try await command.run()

        let databaseURL = projectURL.appendingPathComponent(".universal-search.db")
        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: databaseURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        XCTAssertEqual(envelope.workflowName, "lungfish universal-search")
        XCTAssertEqual(envelope.toolName, "lungfish universal-search")
        XCTAssertTrue(envelope.argv.contains("--reindex"))
        XCTAssertEqual(envelope.output?.path, databaseURL.path)
        XCTAssertEqual(envelope.output?.format, .sqlite)
        XCTAssertNotNil(envelope.output?.checksumSHA256)
        XCTAssertTrue(envelope.files.contains { $0.path == projectURL.path && $0.role == .input && $0.checksumSHA256 != nil })
        XCTAssertEqual(envelope.options.explicit["query"]?.stringValue, "sample:air")
        XCTAssertEqual(envelope.options.resolvedDefaults["limit"]?.integerValue, 200)
    }
}
