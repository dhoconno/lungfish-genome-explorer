// ProvenanceTrackRecordReaderTests.swift - The finder reads each track's own record and an older bundle's shared ones
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 2.13 lane 13.16, items 2, 3 and 6 of the BIO ruling on REC-RUN. A bundle written since 2.13 keeps a
/// mapping record per adopted track and a GATK run record per call. A bundle written before keeps the shared
/// `alignments/mapped/mapping-provenance.json` and `variants/gatk/.lungfish-provenance.json`, which LGE reads
/// and never writes.
final class ProvenanceTrackRecordReaderTests: XCTestCase {
    private var temporaryRoot: URL!
    private var bundle: URL!

    override func setUpWithError() throws {
        temporaryRoot = try TestTempDirectory.make(prefix: "provenance-track-record")
        bundle = temporaryRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Older.lungfish/Sample.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    /// Item 6. The folder walk reads the shared GATK run record of an older bundle for a VCF it names as an
    /// output, and for no other file.
    func testAnOlderBundlesSharedGATKRecordStillReadsForItsVCF() throws {
        let gatkFolder = bundle.appendingPathComponent("variants/gatk", isDirectory: true)
        try FileManager.default.createDirectory(at: gatkFolder, withIntermediateDirectories: true)
        let namedVCF = gatkFolder.appendingPathComponent("vc-1.vcf")
        let otherVCF = gatkFolder.appendingPathComponent("vc-2.vcf")
        for vcf in [namedVCF, otherVCF] {
            try Data("##fileformat=VCFv4.2\n".utf8).write(to: vcf)
        }
        let shared = gatkFolder.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let sharedBytes = try ProvenanceJSON.encoder.encode(
            run(named: "GATK HaplotypeCaller", tool: "gatk-haplotype-caller", outputs: [namedVCF]).canonicalEnvelope()
        )
        try sharedBytes.write(to: shared)

        let found = try XCTUnwrap(ProvenanceRecorder.findProvenanceReading(for: namedVCF), "the shared run record reads for the VCF it names")
        XCTAssertEqual(found.sidecarURL.standardizedFileURL.path, shared.standardizedFileURL.path)
        XCTAssertEqual(found.reading.envelope.workflowName, "GATK HaplotypeCaller")
        XCTAssertNotEqual(
            ProvenanceRecorder.findProvenanceReading(for: otherVCF)?.sidecarURL.standardizedFileURL.path,
            shared.standardizedFileURL.path,
            "the shared run record never stands in for a VCF it does not name"
        )
        XCTAssertEqual(try Data(contentsOf: shared), sharedBytes, "a read never rewrites an older bundle")
    }

    // MARK: Helpers

    private func run(named name: String, tool: String, outputs: [URL], parameters: [String: ParameterValue] = [:]) -> WorkflowRun {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let step = StepExecution(
            toolName: tool,
            toolVersion: "1.0",
            command: [tool],
            inputs: [],
            outputs: outputs.map { ProvenanceRecorder.fileRecord(url: $0, role: .output) },
            exitCode: 0,
            wallTime: 1,
            stderr: nil,
            startTime: date,
            endTime: date
        )
        return WorkflowRun(name: name, startTime: date, endTime: date, status: .completed, steps: [step], parameters: parameters)
    }
}
