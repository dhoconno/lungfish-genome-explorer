// ViralReconResultProvenanceLookupTests.swift - a Viral Recon result finds its run's provenance
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class ViralReconResultProvenanceLookupTests: XCTestCase {
    func testResultFolderFindsTheRecordBesideItsRawResults() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViralReconLookup-\(UUID().uuidString).lungfish")
        let analyses = project.appendingPathComponent("Analyses")
        let result = analyses.appendingPathComponent("viralrecon-2026-09-30T08-44-43")
        let raw = analyses.appendingPathComponent("viralrecon-results-6156f046")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }

        let pointer = #"{"schemaVersion":1,"tool":"viralrecon","rawResultsPath":"@/Analyses/viralrecon-results-6156f046"}"#
        try pointer.write(to: result.appendingPathComponent("viralrecon-result.json"), atomically: true, encoding: .utf8)

        let vcf = raw.appendingPathComponent("sample.vcf.gz")
        try Data().write(to: vcf)
        let output = try ProvenanceFileDescriptor.file(url: vcf, format: .vcf, role: .output)
        let argv = ["lungfish-cli", "workflow", "run", "nf-core/viralrecon"]
        let step = ProvenanceStep(toolName: "nextflow", toolVersion: "25.04", argv: argv,
                                  outputs: [output], exitStatus: 0, wallTimeSeconds: 1)
        let envelope = ProvenanceEnvelope(
            workflowName: "nf-core/viralrecon", workflowVersion: "3.0.0",
            toolName: "nextflow", toolVersion: "25.04", argv: argv,
            files: [output], output: output, outputs: [output], steps: [step],
            wallTimeSeconds: 1, exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: raw)

        let found = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: result))
        XCTAssertEqual(found.sidecarURL.deletingLastPathComponent().standardizedFileURL.path,
                       raw.standardizedFileURL.path)
        XCTAssertEqual(found.envelope.workflowName, "nf-core/viralrecon")
    }
}
