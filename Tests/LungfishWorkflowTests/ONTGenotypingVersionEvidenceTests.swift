// ONTGenotypingVersionEvidenceTests.swift - The pysam version of an ONT genotyping record is a lock pin
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.6, lane P4. Nothing runs pysam to ask its version, so the record names the lock's pin. That
// is a pin and not a measurement, and the evidence says so. The recorded string is the pinned version.

import LungfishIO
import XCTest
@testable import LungfishWorkflow
import LungfishTestSupport

final class ONTGenotypingVersionEvidenceTests: XCTestCase {
    func testThePysamVersionIsTheLockPinForPysam() throws {
        let pinned = try XCTUnwrap(ManagedToolLock.bundled.entry(id: ManagedToolID(rawValue: "pysam"))?.version)
        let evidence = ONTGenotypingPipeline.pysamVersionEvidence
        XCTAssertEqual(evidence, .lockPin(version: pinned, id: ManagedToolID(rawValue: "pysam")))
        XCTAssertEqual(evidence.recordedString, pinned)
        XCTAssertNotEqual(evidence, .observed(version: pinned, reportedLine: nil), "a pin is not a measurement")
    }

    func testThePysamIdIsALockToolsEntry() throws {
        let entry = try XCTUnwrap(ManagedToolLock.bundled.entry(id: ONTGenotypingPipeline.pysamID))
        XCTAssertEqual(entry.environment, "pysam")
        XCTAssertNotNil(ManagedToolLock.bundled.packageSpec(of: entry), "the record names the pinned package")
    }

    /// The written run record names pysam's lock pin as a pin, with the tool's own id, and keeps the
    /// pinned version as the step's version.
    func testTheRecordedPysamStepCarriesLockPinEvidenceAndTheToolId() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ont-genotyping-evidence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reference = root.appendingPathComponent("mhc.fasta")
        try ">DQA1*01\nACGT\n".write(to: reference, atomically: true, encoding: .utf8)
        let input = try makeFASTQBundle(named: "FLD0001", in: root)
        let output = root.appendingPathComponent("out", isDirectory: true)

        let mapping = EvidenceMappingRunner { request in
            try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
            let bam = request.outputDirectory.appendingPathComponent("\(request.sampleName).sorted.bam")
            let bai = request.outputDirectory.appendingPathComponent("\(request.sampleName).sorted.bam.bai")
            try Data("BAM".utf8).write(to: bam)
            try Data("BAI".utf8).write(to: bai)
            return MappingResult(
                mapper: .minimap2, modeID: MappingMode.defaultShortRead.id, bamURL: bam, baiURL: bai,
                totalReads: 10, mappedReads: 9, unmappedReads: 1, wallClockSeconds: 1, contigs: []
            )
        }
        let filter = EvidenceFilterRunner { request in
            try FileManager.default.createDirectory(at: request.outputBAMURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("filtered".utf8).write(to: request.outputBAMURL)
            try Data("index".utf8).write(to: request.outputBAMURL.appendingPathExtension("bai"))
            return ONTGenotypingFilterResult(
                inputBAMURL: request.inputBAMURL, outputBAMURL: request.outputBAMURL,
                outputBAIURL: request.outputBAMURL.appendingPathExtension("bai"), totalAlignments: 4,
                passedAlignments: 3,
                genotypeCounts: [ONTGenotypingGenotypeCount(genotype: "DQA1*01", filteredIndelOnlyMappedReads: 3)],
                stdout: "ok", stderr: "", exitCode: 0, wallClockSeconds: 0.5
            )
        }
        let request = ONTGenotypingRunRequest(
            inputFASTQURLs: [input], referenceSourceURL: reference, outputDirectory: output,
            outputName: "mhc-ont-genotyping", projectURL: nil, threads: 2, minSupport: 1, extraArguments: []
        )
        _ = try await ONTGenotypingPipeline(mappingRunner: mapping, filterRunner: filter).run(request)

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: output))
        let pysamSteps = envelope.steps.filter { $0.toolName == "pysam" }
        XCTAssertEqual(pysamSteps.count, 1)
        let pinned = try XCTUnwrap(ManagedToolLock.bundled.entry(id: ONTGenotypingPipeline.pysamID)?.version)
        for step in pysamSteps {
            XCTAssertEqual(step.managedToolID, ONTGenotypingPipeline.pysamID)
            XCTAssertEqual(step.toolVersionEvidence, .lockPin(version: pinned, id: ONTGenotypingPipeline.pysamID))
            XCTAssertEqual(step.toolVersion, pinned, "the value stays and the source changes")
        }

        // The sample folder's record is built from StepExecution, and its pysam step carries the same facts.
        let sampleEnvelope = try XCTUnwrap(
            ProvenanceRecorder.loadEnvelope(from: output.appendingPathComponent("FLD0001", isDirectory: true))
        )
        let samplePysamSteps = sampleEnvelope.steps.filter { $0.toolName == "pysam" }
        XCTAssertEqual(samplePysamSteps.count, 1)
        for step in samplePysamSteps {
            XCTAssertEqual(step.managedToolID, ONTGenotypingPipeline.pysamID)
            XCTAssertEqual(step.toolVersionEvidence, .lockPin(version: pinned, id: ONTGenotypingPipeline.pysamID))
            XCTAssertEqual(step.toolVersion, pinned, "the value stays and the source changes")
        }

        // The mapping step's version is the read-mapping pack's pin, which is the lock's pin for minimap2.
        let minimap2ID = ManagedToolID(rawValue: "minimap2")
        let minimap2Pin = try XCTUnwrap(ManagedToolLock.bundled.entry(id: minimap2ID)?.version)
        let minimap2Steps = envelope.steps.filter { $0.toolName == "minimap2" }
        XCTAssertEqual(minimap2Steps.count, 1)
        for step in minimap2Steps {
            XCTAssertEqual(step.managedToolID, minimap2ID)
            XCTAssertEqual(step.toolVersionEvidence, .lockPin(version: minimap2Pin, id: minimap2ID))
            XCTAssertEqual(step.toolVersion, minimap2Pin, "the value stays and the source changes")
        }
    }

    private func makeFASTQBundle(named name: String, in root: URL) throws -> URL {
        let bundleURL = root.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent("\(name).fastq")
        try "@\(name)-read1\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)
        let manifest = FASTQDerivedBundleManifest(
            name: name,
            parentBundleRelativePath: ".",
            rootBundleRelativePath: ".",
            rootFASTQFilename: fastqURL.lastPathComponent,
            payload: .full(fastqFilename: fastqURL.lastPathComponent),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .subsampleCount, count: 1),
            cachedStatistics: .countsOnlyFixture(readCount: 1, baseCount: 4),
            pairingMode: .singleEnd,
            sequenceFormat: .fastq,
            payloadChecksums: nil,
            materializationState: .materialized(checksum: "")
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        return bundleURL
    }
}

private struct EvidenceMappingRunner: ONTGenotypingMappingRunning {
    let handler: @Sendable (MappingRunRequest) async throws -> MappingResult

    func runMapping(
        request: MappingRunRequest,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> MappingResult {
        try await handler(request)
    }
}

private struct EvidenceFilterRunner: ONTGenotypingPysamFiltering {
    let handler: @Sendable (ONTGenotypingFilterRequest) async throws -> ONTGenotypingFilterResult

    func filter(_ request: ONTGenotypingFilterRequest) async throws -> ONTGenotypingFilterResult {
        try await handler(request)
    }
}
