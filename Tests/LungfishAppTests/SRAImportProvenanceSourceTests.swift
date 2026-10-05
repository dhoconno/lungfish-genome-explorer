// SRAImportProvenanceSourceTests.swift - The SRA import provenance names the environment of its source
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishWorkflow
@testable import LungfishApp

/// The window's SRA import provenance records which environment fetched the
/// reads. Every SRA Toolkit source ran prefetch and fasterq-dump in the
/// managed sra-tools environment, but the record compared the source with
/// "SRA Toolkit" exactly, so "SRA Toolkit (ENA mirror incomplete)" recorded
/// the environment as "none".
final class SRAImportProvenanceSourceTests: XCTestCase {

    func testEverySRAToolkitSourceRecordsTheSRAToolsEnvironment() throws {
        for downloadSource in ["SRA Toolkit", "SRA Toolkit (ENA mirror incomplete)", "SRA Toolkit (ENA transfer failed)"] {
            let parameters = try Self.recordedParameters(downloadSource: downloadSource)
            XCTAssertEqual(parameters["downloadSource"], .string(downloadSource))
            XCTAssertEqual(parameters["condaEnvironment"], .string("managed sra-tools"), downloadSource)
        }
    }

    func testENASourceRecordsNoEnvironment() throws {
        let parameters = try Self.recordedParameters(downloadSource: "ENA")
        XCTAssertEqual(parameters["downloadSource"], .string("ENA"))
        XCTAssertEqual(parameters["condaEnvironment"], .string("none"))
    }

    private static func recordedParameters(downloadSource: String) throws -> [String: ParameterValue] {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SRAImportProvenanceSource-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundleURL = temp.appendingPathComponent("SRR27069570.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent("SRR27069570.fastq.gz")
        try Data([0x1F, 0x8B]).write(to: fastqURL)

        // `lungfish-cli import fastq` writes the bundle's provenance first and
        // the window's record keeps it, as in a real import.
        try WorkflowRun(
            name: "fastq-import",
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 1),
            status: .completed,
            appVersion: "lungfish-cli test",
            hostOS: WorkflowRun.currentHostOS,
            steps: [],
            parameters: [:]
        ).writeSidecar(to: bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename))

        try writeGUISRAFASTQImportProvenance(
            accession: "SRR27069570",
            readRecord: nil,
            downloadSource: downloadSource,
            enaDownloadSteps: [],
            toolkitDownloadTraces: [],
            cliArguments: ["import", "fastq"],
            cliStartedAt: Date(timeIntervalSince1970: 0),
            cliCompletedAt: Date(timeIntervalSince1970: 1),
            stagedFASTQFiles: [],
            finalFASTQURL: fastqURL,
            bundleURL: bundleURL,
            platform: "illumina",
            recipeName: nil,
            qualityBinning: "none",
            optimizeStorage: false,
            compressionLevel: "balanced"
        )
        let run = try XCTUnwrap(ProvenanceRecorder.load(from: bundleURL))
        XCTAssertEqual(run.name, "gui-sra-fastq-import")
        return run.parameters
    }
}
