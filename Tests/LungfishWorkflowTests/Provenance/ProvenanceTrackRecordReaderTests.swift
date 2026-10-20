// ProvenanceTrackRecordReaderTests.swift - The finder reads each track's own record and an older bundle's shared ones
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 2.13 lane 13.16, items 2 and 6 of the BIO ruling on REC-RUN. A bundle written since 2.13 keeps a
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
            TrackRecordFixtures.run(named: "GATK HaplotypeCaller", tool: "gatk-haplotype-caller", outputs: [namedVCF]).canonicalEnvelope()
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

    /// Item 2. A track's `<bam stem>.mapping-provenance.json` reads as a typed record for the track's BAM and for
    /// the record itself, through the finder and the project index, and never as the Older record format.
    func testTheFinderReadsATracksMappingRecordAsATypedRecord() throws {
        let mapped = bundle.appendingPathComponent("alignments/mapped", isDirectory: true)
        try FileManager.default.createDirectory(at: mapped, withIntermediateDirectories: true)
        let bam = mapped.appendingPathComponent("track.bam")
        try Data("bam".utf8).write(to: bam)
        let recordURL = MappingProvenance.trackRecordURL(forAlignmentAt: bam)
        XCTAssertEqual(recordURL.lastPathComponent, "track.mapping-provenance.json")
        try TrackRecordFixtures.mappingRecord(sample: "track", in: temporaryRoot, bundle: bundle).save(toFile: recordURL)
        XCTAssertTrue(MappingProvenance.isRecordFilename(recordURL.lastPathComponent))
        XCTAssertTrue(MappingProvenance.isRecordFilename(MappingProvenance.filename))
        XCTAssertFalse(MappingProvenance.isRecordFilename(".mapping-provenance.json"))
        XCTAssertFalse(MappingProvenance.isRecordFilename("track.adopt-mapping-provenance.json"))

        for selected in [bam, recordURL] {
            let found = try XCTUnwrap(ProvenanceRecorder.findProvenanceReading(for: selected), selected.lastPathComponent)
            XCTAssertEqual(found.sidecarURL.standardizedFileURL.path, recordURL.standardizedFileURL.path)
            XCTAssertEqual(found.reading.shape, .typedRecord, "never the Older record format")
            XCTAssertEqual(found.reading.envelope.workflowName, "lungfish map")
        }
        if let found = ProvenanceRecorder.findProvenanceReading(for: mapped),
           found.sidecarURL.standardizedFileURL.path == recordURL.standardizedFileURL.path {
            XCTAssertEqual(found.reading.shape, .typedRecord, "the tolerant reader never reads a track's mapping record")
        }
        XCTAssertEqual(ProvenanceSidecarIndex.readRecord(at: recordURL)?.workflowName, "lungfish map")
    }
}

/// Records the 13.16 reader tests place in a bundle.
enum TrackRecordFixtures {
    static func run(named name: String, tool: String, outputs: [FileRecord], parameters: [String: ParameterValue] = [:]) -> WorkflowRun {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let step = StepExecution(
            toolName: tool,
            toolVersion: "1.0",
            command: [tool],
            inputs: [],
            outputs: outputs,
            exitCode: 0,
            wallTime: 1,
            stderr: nil,
            startTime: date,
            endTime: date
        )
        return WorkflowRun(name: name, startTime: date, endTime: date, status: .completed, steps: [step], parameters: parameters)
    }

    static func run(named name: String, tool: String, outputs: [URL]) -> WorkflowRun {
        run(named: name, tool: tool, outputs: outputs.map { ProvenanceRecorder.fileRecord(url: $0, role: .output) })
    }

    /// A typed record of a `lungfish map` run of `sample`, whose files sit in a folder of its own under `root`.
    static func mappingRecord(sample: String, in root: URL, bundle: URL) throws -> MappingProvenance {
        let folder = root.appendingPathComponent("mapping-\(sample)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fastq = folder.appendingPathComponent("\(sample).fastq")
        let reference = folder.appendingPathComponent("reference.fa")
        try Data("@r\nACGT\n+\nIIII\n".utf8).write(to: fastq)
        try Data(">chr1\nACGT\n".utf8).write(to: reference)
        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.minimap2MapONT.id,
            inputFASTQURLs: [fastq],
            referenceFASTAURL: reference,
            sourceReferenceBundleURL: bundle,
            outputDirectory: folder,
            sampleName: sample,
            threads: 1,
            includeSecondary: false,
            includeSupplementary: false,
            minimumMappingQuality: 0,
            advancedArguments: []
        )
        let result = MappingResult(
            mapper: .minimap2,
            modeID: request.modeID,
            sourceReferenceBundleURL: bundle,
            viewerBundleURL: bundle,
            bamURL: folder.appendingPathComponent("sorted.bam"),
            baiURL: folder.appendingPathComponent("sorted.bam.bai"),
            totalReads: 1,
            mappedReads: 1,
            unmappedReads: 0,
            wallClockSeconds: 1,
            contigs: []
        )
        return MappingProvenance.build(
            request: request,
            result: result,
            mapperInvocation: MappingCommandInvocation(label: "minimap2", argv: ["minimap2", "-a", reference.path, fastq.path]),
            normalizationInvocations: [],
            mapperVersion: "2.28",
            samtoolsVersion: "1.21",
            recordedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }
}
