// CzIdImportWorkflowTests.swift - App-side CZ-ID import workflow coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishWorkflow
@testable import LungfishApp

final class CzIdImportWorkflowTests: XCTestCase {
    func testProjectImportWorkflowWritesClassificationBundleWithFirstClassProvenance() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projectURL = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let sourceURL = tempDir.appendingPathComponent("source report.tsv")
        try czIdReportText().write(to: sourceURL, atomically: true, encoding: .utf8)

        let imported = try await CzIdProjectImportWorkflow.importFromURL(
            sourceURL,
            projectURL: projectURL,
            sampleName: "GUI Sample 01"
        )

        let bundleURL = projectURL
            .appendingPathComponent("Classifications", isDirectory: true)
            .appendingPathComponent("GUI-Sample-01.lungfishtax", isDirectory: true)
        XCTAssertEqual(imported.bundleURL.standardizedFileURL, bundleURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("classification.czid.tsv").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("classification-result.json").path))

        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let provenance = try decoder.decode(WorkflowRun.self, from: try Data(contentsOf: provenanceURL))
        let step = try XCTUnwrap(provenance.steps.first)
        XCTAssertEqual(step.toolName, "lungfish import cz-id")
        XCTAssertEqual(step.command, [
            "lungfish",
            "import",
            "cz-id",
            sourceURL.path,
            "--project",
            projectURL.standardizedFileURL.path,
            "--sample-name",
            "GUI Sample 01",
        ])
        XCTAssertFalse(step.command.joined(separator: " ").contains("cz-id import"))
        XCTAssertFalse(step.command.contains("--output-dir"))
        XCTAssertEqual(provenance.parameters["outputBundle"]?.fileValue?.standardizedFileURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(provenance.parameters["reportPayload"]?.fileValue?.standardizedFileURL, bundleURL.appendingPathComponent("classification.czid.tsv").standardizedFileURL)
    }

    func testProjectImportWorkflowUsesPreviewSampleNameWhenNotProvided() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projectURL = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let sourceURL = tempDir.appendingPathComponent("taxon_report.tsv")
        try czIdReportText().write(to: sourceURL, atomically: true, encoding: .utf8)

        let imported = try await CzIdProjectImportWorkflow.importFromURL(sourceURL, projectURL: projectURL)

        XCTAssertEqual(imported.sampleName, "Sample-CZ-001")
        XCTAssertEqual(imported.bundleURL.lastPathComponent, "Sample-CZ-001.lungfishtax")
    }

    func testPreviewDetectsExtractedFolderReportAndSummarizesSample() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let exportDir = tempDir.appendingPathComponent("czid-export", isDirectory: true)
        let reportsDir = exportDir.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)
        let reportURL = reportsDir.appendingPathComponent("taxon_report.tsv")
        try czIdReportText().write(to: reportURL, atomically: true, encoding: .utf8)

        let preview = try await CzIdImportPreview.scan(exportDir)

        XCTAssertEqual(preview.sourceKind, .extractedFolder)
        XCTAssertEqual(preview.sampleName, "Sample-CZ-001")
        XCTAssertEqual(preview.projectId, "Project-42")
        XCTAssertEqual(preview.pipelineVersion, "8.4")
        XCTAssertEqual(preview.ntDatabaseVersion, "nt_2025_12_01")
        XCTAssertEqual(preview.nrDatabaseVersion, "nr_2025_12_01")
        XCTAssertEqual(preview.rowCount, 3)
        XCTAssertEqual(preview.reportURL.standardizedFileURL, reportURL.standardizedFileURL)
    }

    func testPreviewDetectsZipArchiveReport() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let payloadDir = tempDir.appendingPathComponent("payload", isDirectory: true)
        let nestedDir = payloadDir.appendingPathComponent("czid/results", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try czIdReportText().write(
            to: nestedDir.appendingPathComponent("taxon_report.tsv"),
            atomically: true,
            encoding: .utf8
        )
        let archiveURL = tempDir.appendingPathComponent("czid-export.zip")
        try makeZipArchive(from: payloadDir, to: archiveURL)

        let preview = try await CzIdImportPreview.scan(archiveURL)

        XCTAssertEqual(preview.sourceKind, .zipArchive)
        XCTAssertEqual(preview.sourceArchiveURL?.standardizedFileURL, archiveURL.standardizedFileURL)
        XCTAssertEqual(preview.sampleName, "Sample-CZ-001")
        XCTAssertEqual(preview.rowCount, 3)
        XCTAssertEqual(preview.reportFileName, "taxon_report.tsv")
    }

    func testAppConversionRecordsArchiveChecksumAndFinalPayloadInProvenance() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reportURL = tempDir.appendingPathComponent("taxon_report.tsv")
        try czIdReportText().write(to: reportURL, atomically: true, encoding: .utf8)
        let archiveURL = tempDir.appendingPathComponent("czid-export.zip")
        try Data("archive bytes".utf8).write(to: archiveURL)
        let outputDirectory = tempDir.appendingPathComponent("cz-id-imported", isDirectory: true)

        let converted = try CzIdDataConverter.convertTaxonReport(
            at: reportURL,
            outputDirectory: outputDirectory,
            command: ["lungfish", "cz-id", "import", archiveURL.path, "--output-dir", outputDirectory.path],
            sourceInputURL: archiveURL
        )

        let finalPayloadURL = outputDirectory.appendingPathComponent("classification.czid.tsv")
        XCTAssertEqual(converted.manifest?.sourceFiles.map(\.standardizedFileURL), [finalPayloadURL.standardizedFileURL])

        let provenanceURL = outputDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let provenance = try XCTUnwrap(jsonObject(at: provenanceURL))
        let steps = try XCTUnwrap(provenance["steps"] as? [[String: Any]])
        let firstStep = try XCTUnwrap(steps.first)
        let inputs = try XCTUnwrap(firstStep["inputs"] as? [[String: Any]])
        let archiveRecord = try XCTUnwrap(inputs.first { ($0["path"] as? String) == archiveURL.path })
        XCTAssertEqual(archiveRecord["sizeBytes"] as? Int, 13)
        XCTAssertFalse((archiveRecord["sha256"] as? String ?? "").isEmpty)

        let outputs = try XCTUnwrap(firstStep["outputs"] as? [[String: Any]])
        XCTAssertTrue(outputs.contains { ($0["path"] as? String) == finalPayloadURL.path })
    }

    func testZipConversionProvenanceParametersDoNotRecordTemporaryExtractionPath() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let extractedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("czid-preview-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: extractedDir, withIntermediateDirectories: true)
        let reportURL = extractedDir.appendingPathComponent("taxon_report.tsv")
        try czIdReportText().write(to: reportURL, atomically: true, encoding: .utf8)
        let archiveURL = tempDir.appendingPathComponent("czid-export.zip")
        try Data("archive bytes".utf8).write(to: archiveURL)
        let outputDirectory = tempDir.appendingPathComponent("zip-import.lungfishtax", isDirectory: true)

        _ = try CzIdDataConverter.convertTaxonReport(
            at: reportURL,
            outputDirectory: outputDirectory,
            command: ["lungfish", "import", "cz-id", archiveURL.path, "--project", tempDir.path, "--sample-name", "Zip Sample"],
            sourceInputURL: archiveURL,
            sampleNameOverride: "Zip Sample",
            provenanceToolName: "lungfish import cz-id"
        )

        let provenanceURL = outputDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let provenance = try decoder.decode(WorkflowRun.self, from: try Data(contentsOf: provenanceURL))
        let parameterPaths = provenance.parameters.values.compactMap(\.fileValue).map(\.path)
        XCTAssertFalse(parameterPaths.contains { $0.contains("/czid-preview-") }, parameterPaths.joined(separator: "\n"))
        XCTAssertEqual(
            provenance.parameters["reportPayload"]?.fileValue?.standardizedFileURL,
            outputDirectory.appendingPathComponent("classification.czid.tsv").standardizedFileURL
        )
        XCTAssertEqual(provenance.parameters["sourcePath"]?.fileValue?.standardizedFileURL, archiveURL.standardizedFileURL)
    }

    @MainActor
    func testCzIdResultControllerEmbedsTaxonomyView() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reportURL = tempDir.appendingPathComponent("taxon_report.tsv")
        try czIdReportText().write(to: reportURL, atomically: true, encoding: .utf8)
        let outputDirectory = tempDir.appendingPathComponent("cz-id-imported", isDirectory: true)
        let converted = try CzIdDataConverter.convertTaxonReport(
            at: reportURL,
            outputDirectory: outputDirectory
        )

        let controller = CzIdResultViewController()
        controller.configure(
            result: converted.result,
            manifest: try XCTUnwrap(converted.manifest),
            bundleURL: outputDirectory
        )
        _ = controller.view

        XCTAssertEqual(controller.view.accessibilityIdentifier(), "czid-result-view")
        XCTAssertNotNil(controller.taxonomyViewControllerForTesting)
    }

    private func czIdReportText() -> String {
        """
        sample_name\tproject_id\tpipeline_version\tnt_db_version\tnr_db_version\ttax_id\ttaxon_name\trank\tnt_read_count\tnt_rpm\tnr_read_count\tnr_rpm
        Sample-CZ-001\tProject-42\t8.4\tnt_2025_12_01\tnr_2025_12_01\t1\troot\troot\t1200\t1000000\t1200\t1000000
        Sample-CZ-001\tProject-42\t8.4\tnt_2025_12_01\tnr_2025_12_01\t10239\tViruses\tsuperkingdom\t88\t73333\t12\t10000
        Sample-CZ-001\tProject-42\t8.4\tnt_2025_12_01\tnr_2025_12_01\t2697049\tSevere acute respiratory syndrome coronavirus 2\tspecies\t42\t35000\t5\t4166.7
        """
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("czid-import-workflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeZipArchive(from directory: URL, to archiveURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-qry", archiveURL.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func jsonObject(at url: URL) throws -> [String: Any]? {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
