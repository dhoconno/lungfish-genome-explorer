// SRAImportProvenanceSourceTests.swift - The SRA import provenance names the environment of its source
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
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

    /// `naming(tool:version:)` lists every field of `ProvenanceEnvelope` by hand, so a field added to the envelope
    /// and left out there would vanish from the SRA record with no test failing. The same arguments written with
    /// no run tool and with `lungfish-cli` at a version differ in the run tool's fields and nowhere else
    /// (Phase 2.11 A60 M3 review, Fix 8).
    func testTheRunToolIsTheOnlyFieldThatNamingChanges() throws {
        let plain = try Self.writtenRecord(runTool: nil)
        let named = try Self.writtenRecord(runTool: (name: "lungfish-cli", version: "9.9.9"))

        XCTAssertEqual(named.envelope.toolName, "lungfish-cli")
        XCTAssertEqual(named.envelope.toolVersion, "9.9.9")
        XCTAssertEqual(named.envelope.tool.kind, "cli")
        XCTAssertFalse(named.envelope.steps.isEmpty, "the comparison covers the steps")
        XCTAssertEqual(named.masked, plain.masked, "the run tool is the only field the rebuild changes")
    }

    /// One record written from fixed arguments into a fresh bundle folder, as the envelope the file holds and as
    /// its JSON text without the fields a second write or a named run tool may change. The ids, the time and the
    /// run tool's own fields are dropped, and the UUIDs left in values (the folder names in paths) are masked.
    private static func writtenRecord(
        runTool: (name: String, version: String)?
    ) throws -> (envelope: ProvenanceEnvelope, masked: String) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SRAImportProvenanceSource-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundleURL = temp.appendingPathComponent("SRR27069570.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent("SRR27069570.fastq.gz")
        try Data([0x1F, 0x8B]).write(to: fastqURL)
        let stagedURL = temp.appendingPathComponent("SRR27069570.fastq")
        try Data("@r\nACGT\n+\nIIII\n".utf8).write(to: stagedURL)

        try writeGUISRAFASTQImportProvenance(
            accession: "SRR27069570",
            readRecord: nil,
            downloadSource: "ENA",
            enaDownloadSteps: [],
            toolkitDownloadTraces: [],
            cliArguments: ["import", "fastq"],
            cliCommandLine: "lungfish-cli import fastq",
            cliStartedAt: Date(timeIntervalSince1970: 0),
            cliCompletedAt: Date(timeIntervalSince1970: 1),
            stagedFASTQFiles: [stagedURL],
            finalFASTQURL: fastqURL,
            bundleURL: bundleURL,
            platform: "illumina",
            recipeName: nil,
            qualityBinning: "none",
            optimizeStorage: false,
            compressionLevel: "balanced",
            // Never the locator, which can wait on the build lock `swift test` holds.
            cliBinaryPath: { URL(fileURLWithPath: "/injected/lungfish-cli") },
            runTool: runTool
        )
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundleURL))
        let data = try Data(contentsOf: bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["id", "createdAt", "tool", "toolName", "toolVersion"] { object[key] = nil }
        object["steps"] = (object["steps"] as? [[String: Any]])?.map { step in
            var step = step
            step["id"] = nil
            step["dependsOn"] = nil
            return step
        }
        let text = String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]),
            as: UTF8.self)
        let context = OutputEquivalence.MaskContext(rootA: temp, rootB: temp)
        return (envelope, OutputEquivalence.Masks.uuids(text, context: context))
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
            cliCommandLine: CLIImportRunner.commandLine(arguments: ["import", "fastq"]),
            cliStartedAt: Date(timeIntervalSince1970: 0),
            cliCompletedAt: Date(timeIntervalSince1970: 1),
            stagedFASTQFiles: [],
            finalFASTQURL: fastqURL,
            bundleURL: bundleURL,
            platform: "illumina",
            recipeName: nil,
            qualityBinning: "none",
            optimizeStorage: false,
            compressionLevel: "balanced",
            // Never the locator, which can wait on the build lock `swift test` holds.
            cliBinaryPath: { URL(fileURLWithPath: "/injected/lungfish-cli") }
        )
        let run = try XCTUnwrap(ProvenanceRecorder.load(from: bundleURL))
        XCTAssertEqual(run.name, "sra-fastq-download-bundle")
        return run.parameters
    }
}
