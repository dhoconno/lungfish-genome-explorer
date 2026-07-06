// ImportCzIdCommandTests.swift - First-class CZ-ID project import coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ImportCzIdCommandTests: XCTestCase {
    func testImportCommandRegistersCzIdSubcommand() {
        let registeredNames = ImportCommand.configuration.subcommands.map { subcommand in
            subcommand.configuration.commandName
        }

        XCTAssertTrue(registeredNames.contains("cz-id"))
    }

    func testImportCzIdCreatesProjectClassificationBundleWithProvenance() async throws {
        let fixture = try fixtureURL("czid/minimal_taxon_report.tsv")
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("czid-project-\(UUID().uuidString).lungfish", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let command = try ImportCommand.CzIdSubcommand.parse([
            fixture.path,
            "--project", projectURL.path,
            "--sample-name", "Imported-CZ-Sample",
            "--quiet",
        ])

        try await command.run()

        let bundleURL = projectURL
            .appendingPathComponent("Classifications", isDirectory: true)
            .appendingPathComponent("Imported-CZ-Sample.lungfishtax", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("classification.kreport").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("classification-result.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("classification.czid.tsv").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("cz-id-manifest.json").path))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try ClassificationResult.load(from: bundleURL)
        XCTAssertEqual(result.config.databaseName, "CZ-ID")
        XCTAssertEqual(result.config.databaseVersion, "nt=nt_2025_12_01; nr=nr_2025_12_01")
        XCTAssertEqual(result.config.inputFiles.map(\.standardizedFileURL), [bundleURL.appendingPathComponent("classification.czid.tsv").standardizedFileURL])
        XCTAssertEqual(result.toolVersion, "8.4")
        XCTAssertEqual(result.tree.node(taxId: 2697049)?.readsDirect, 42)

        let manifest = try decoder.decode(
            CzIdImportManifest.self,
            from: try Data(contentsOf: bundleURL.appendingPathComponent("cz-id-manifest.json"))
        )
        XCTAssertEqual(manifest.sourceFiles.map(\.standardizedFileURL), [bundleURL.appendingPathComponent("classification.czid.tsv").standardizedFileURL])

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: bundleURL))
        XCTAssertEqual(provenance.workflowName, "CZ-ID Import")
        XCTAssertEqual(provenance.exitStatus, 0)
        XCTAssertEqual(provenance.options.resolvedDefaults["sampleName"]?.stringValue, "Imported-CZ-Sample")
        XCTAssertEqual(provenance.options.resolvedDefaults["czIdSchemaVersion"]?.stringValue, "cz-id-taxon-report-v1")
        XCTAssertEqual(provenance.options.resolvedDefaults["pipelineVersion"]?.stringValue, "8.4")
        XCTAssertEqual(provenance.options.resolvedDefaults["ntDatabaseVersion"]?.stringValue, "nt_2025_12_01")
        XCTAssertEqual(provenance.options.resolvedDefaults["nrDatabaseVersion"]?.stringValue, "nr_2025_12_01")

        let step = try XCTUnwrap(provenance.steps.first)
        XCTAssertEqual(step.toolName, "lungfish import cz-id")
        XCTAssertEqual(step.argv, [
            "lungfish-cli",
            "import",
            "cz-id",
            fixture.path,
            "--project",
            projectURL.standardizedFileURL.path,
            "--sample-name",
            "Imported-CZ-Sample",
        ])
        XCTAssertEqual(step.exitStatus, 0)
        XCTAssertNotNil(step.wallTimeSeconds)
        XCTAssertTrue(step.inputs.contains { $0.path == fixture.path && $0.checksumSHA256 != nil && $0.fileSize != nil })
        XCTAssertTrue(step.outputs.contains {
            $0.path == bundleURL.appendingPathComponent("classification-result.json").path
                && $0.checksumSHA256 != nil
                && $0.fileSize != nil
        })
        XCTAssertEqual(
            provenance.options.resolvedDefaults["reportPayload"]?.fileValue?.standardizedFileURL,
            bundleURL.appendingPathComponent("classification.czid.tsv").standardizedFileURL
        )
    }

    private func fixtureURL(_ relativePath: String) throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Tests/Fixtures/\(relativePath)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("Missing fixture \(relativePath)")
    }
}
