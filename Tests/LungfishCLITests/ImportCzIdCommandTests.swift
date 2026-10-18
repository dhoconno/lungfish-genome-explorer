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
        // The Sample column shows this, not the payload stem "classification.czid".
        XCTAssertEqual(result.config.sampleDisplayName, "Imported-CZ-Sample")
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
            // The fixture lies outside the project, so only its name is kept.
            "<external>/\(fixture.lastPathComponent)",
            "--project",
            projectURL.standardizedFileURL.path,
            "--sample-name",
            "Imported-CZ-Sample",
        ])
        XCTAssertEqual(step.exitStatus, 0)
        XCTAssertNotNil(step.wallTimeSeconds)
        XCTAssertTrue(step.inputs.contains { $0.path == "<external>/\(fixture.lastPathComponent)" && $0.checksumSHA256 != nil && $0.fileSize != nil })
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

    /// Phase 2.12 lane 12.06, review 12.06-M1 fix 7. A taxon report without the `tax_id` column cannot be
    /// converted. The leaf ends with a `failed` event that says why and exit 5 (`formatError`), and publishes no
    /// bundle.
    func testAReportThatCannotBeConvertedExitsWithFormatErrorAndPublishesNothing() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let source = try scratch.write(
            "inputs/taxon_report.tsv",
            "sample_name\ttaxon_name\trank\tnt_read_count\nBroken-Sample\tViruses\tsuperkingdom\t88\n"
        )
        let command = try ImportCommand.CzIdSubcommand.parse([
            source.path, "--project", scratch.project.path, "--sample-name", "Broken Sample", "--format", "json",
        ])
        let output = try await ImportStreamCapture.capture(in: scratch) { try await command.run() }

        let exit = try XCTUnwrap(output.thrown as? ExitCode, "\(String(describing: output.thrown))")
        XCTAssertEqual(exit.rawValue, CLIExitCode.formatError.exitCode.rawValue)
        let last = try XCTUnwrap(output.standardOutput.last, "the leaf printed no event")
        let event = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any], last)
        XCTAssertEqual(event["event"] as? String, "failed", last)
        XCTAssertFalse(((event["error"] as? String) ?? "").isEmpty, last)
        let classifications = scratch.project.appendingPathComponent("Classifications", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: classifications.path)) ?? []
        XCTAssertEqual(entries.filter { $0.hasSuffix(".lungfishtax") }, [], "a failed conversion publishes no bundle")
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
