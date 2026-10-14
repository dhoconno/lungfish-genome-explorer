// AlignmentReadExtractionPublicationPinTests.swift - Today's region and selected-read bundles and records, before extract reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A51 M3, the freeze before `lungfish-cli extract reads` publishes the viewer's
// Extract Reads in Selected Region and Extract Selected Reads (census row 22, gaps
// alignment-region-reads and alignment-selected-reads, QA 1). It pins, from the coordinator the
// base runs in the app, what each run hands its stager, the files the bundle destination leaves
// and the record the publisher writes, read back from disk. The stagers are stand-ins that stage
// a known FASTQ with one samtools record, so the pin needs no tool. The text names the scratch
// folder `<root>`, the app's version `<app version>` and each staging UUID `<uuid>`.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class AlignmentReadExtractionPublicationPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "read-extraction-pin")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("out"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// Evidence with known bytes and every filter set, as the viewer holds it.
    private func context() throws -> AlignmentActionContext {
        let evidence = root.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let bam = evidence.appendingPathComponent("sample.bam")
        let index = evidence.appendingPathComponent("sample.bam.bai")
        try Data("bam bytes".utf8).write(to: bam)
        try Data("index bytes".utf8).write(to: index)
        return try AlignmentActionContext(
            identity: .init(workflow: "mapping", resultID: "run-1", sampleID: "S1", evidenceID: "virus"),
            alignmentURL: bam, indexURL: index, decodingReferenceURL: nil,
            contig: "virus", contigLength: 40,
            alignmentSnapshot: .init(url: bam, byteCount: 9, sha256: try ProvenanceFileHasher.sha256(of: bam)),
            indexSnapshot: .init(url: index, byteCount: 11, sha256: try ProvenanceFileHasher.sha256(of: index)),
            decodingReferenceSnapshot: nil,
            filters: .init(minimumDepth: 3, minimumMapQ: 20, minimumBaseQuality: 12, excludedFlags: 0x904, readGroups: ["rg2", "rg1"]),
            outputCapability: .userSelectedDestination, sourceReads: .bamFallback,
            presentationLabel: "S1 virus"
        )
    }

    /// What a stager hands back: two reads staged as `<name>.fastq` with the samtools record that wrote them.
    private func transaction(named name: String, missing: Int = 0, message: String? = nil) throws -> AlignmentReadExtractionTransaction {
        let staging = root.appendingPathComponent("staging-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let payload = staging.appendingPathComponent("\(name).fastq")
        try "@read-1\nACGT\n+\nIIII\n@read-2\nTTGA\n+\nIIII\n".write(to: payload, atomically: true, encoding: .utf8)
        let started = Date(timeIntervalSince1970: 100)
        let record = AlignmentReadExtractionExecutionRecord(
            stage: .payloadStaging, toolName: "samtools", toolVersion: "samtools 1.23.1", executablePath: "/managed/samtools",
            argv: ["/managed/samtools", "fastq", "-o", payload.path, staging.appendingPathComponent("filtered.bam").path],
            inputs: [], outputs: [], exitStatus: 0,
            startedAt: started, completedAt: started.addingTimeInterval(1), stderr: "tool-note"
        )
        return try AlignmentReadExtractionTransaction(
            stagingDirectoryURL: staging,
            stagedFiles: [.init(stagedURL: payload, relativeFinalPath: "\(name).fastq", format: .fastq)],
            readCount: 2, pairedEnd: false,
            recordsWithoutSequence: missing, missingSequenceMessage: message,
            executionRecords: [record]
        )
    }

    private func masked(_ text: String) -> String {
        text.replacingOccurrences(of: root.standardizedFileURL.path, with: "<root>")
            .replacingOccurrences(of: WorkflowRun.currentAppVersion, with: "<app version>")
            .replacingOccurrences(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, with: "<uuid>", options: .regularExpression)
    }

    /// The regular files under `out`, relative and sorted.
    private func files() -> [String] {
        let folder = root.appendingPathComponent("out")
        let base = folder.standardizedFileURL.path + "/"
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        var paths: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            paths.append(masked(url.standardizedFileURL.path.replacingOccurrences(of: base, with: "")))
        }
        return paths.sorted()
    }

    /// The record's facts as lines.
    private func describe(_ envelope: ProvenanceEnvelope) throws -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func text(_ value: ParameterValue) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        func options(_ values: [String: ParameterValue]) throws -> String {
            try values.keys.sorted().map { "\($0)=\(try text(values[$0]!))" }.joined(separator: " ")
        }
        var lines = [
            "workflow \(envelope.workflowName) \(envelope.workflowVersion ?? "nil")",
            "tool \(envelope.toolName) \(envelope.toolVersion) kind \(envelope.tool.kind ?? "nil")",
            "argv \(envelope.argv.joined(separator: " "))",
            "replay \(envelope.durableReplayArgv?.joined(separator: " ") ?? "nil")",
            "explicit \(try options(envelope.options.explicit))",
            "defaults \(try options(envelope.options.defaults))",
            "resolved \(try options(envelope.options.resolvedDefaults))",
            "runtime \(envelope.runtimeIdentity.appVersion ?? "nil")",
        ]
        lines += envelope.files.map { "file \($0.role) \($0.format.map { "\($0)" } ?? "nil") \($0.path)" }
        lines.append("output \(envelope.output?.path ?? "nil")")
        lines += envelope.steps.map { "step \($0.toolName) \($0.toolVersion) \($0.argv.joined(separator: " "))" }
        lines.append("end \(envelope.status.rawValue) exit \(envelope.exitStatus.map(String.init) ?? "nil") stderr \(envelope.stderr ?? "nil")")
        return lines.map(masked)
    }

    // MARK: - Cases

    func testARegionExtractionStagesTheEvidenceFiltersAndPublishesTodaysBundleAndRecord() async throws {
        var staged: BAMRegionExtractionConfig?
        let coordinator = AlignmentScientificActionCoordinator(
            validator: { _ in },
            regionStager: { config in
                staged = config
                return try self.transaction(named: "selected-region")
            }
        )
        let destination = root.appendingPathComponent("out/selected-region.lungfishfastq")
        let result = try await coordinator.extractRegion(
            context: try context(),
            region: .init(scope: .selectedRegion, contig: "virus", start: 10, end: 15),
            destination: .bundle(destination),
            outputBaseName: "selected-region"
        )

        let config = try XCTUnwrap(staged)
        XCTAssertEqual([
            "bam \(config.bamURL.path)", "index \(config.indexURL?.path ?? "nil")", "reference \(config.decodingReferenceURL?.path ?? "nil")",
            "regions \(config.regions.joined(separator: " ")) fallbackToAll \(config.fallbackToAll)",
            "minMapQ \(config.minMapQ.map(String.init) ?? "nil") excludedFlags \(config.excludedFlags.map(String.init) ?? "nil")",
            "readGroups \(config.readGroups.joined(separator: ",")) deduplicate \(config.deduplicateReads)",
            "output \(config.outputDirectory.path) \(config.outputBaseName)",
        ].map(masked), Self.regionConfig)
        XCTAssertEqual(files(), Self.regionFiles)
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertEqual(try describe(record), Self.regionRecord)
    }

    func testASelectedReadsExtractionStagesTheNamesAndPublishesTodaysBundleAndRecord() async throws {
        var staged: (config: ReadIDBAMExtractionConfig, missing: Int, message: String?)?
        let coordinator = AlignmentScientificActionCoordinator(
            validator: { _ in },
            bamStager: { config, missing, message in
                staged = (config, missing, message)
                return try self.transaction(named: "S1_virus_selected_2reads", missing: missing, message: message)
            }
        )
        let reads = [
            AlignedRead(name: "read-2", flag: 0, chromosome: "virus", position: 12, mapq: 60, cigar: [], sequence: "TTGA", qualities: [40, 40, 40, 40]),
            AlignedRead(name: "read-1", flag: 0, chromosome: "virus", position: 10, mapq: 60, cigar: [], sequence: "ACGT", qualities: [40, 40, 40, 40]),
            AlignedRead(name: "read-1", flag: 256, chromosome: "virus", position: 20, mapq: 0, cigar: [], sequence: "*", qualities: []),
        ]
        let destination = root.appendingPathComponent("out/S1_virus_selected_2reads.lungfishfastq")
        let result = try await coordinator.extractSelectedReads(
            context: try context(), records: reads, destination: .bundle(destination), outputBaseName: "S1_virus_selected_2reads"
        )

        let stage = try XCTUnwrap(staged)
        XCTAssertEqual([
            "bam \(stage.config.bamURL.path)", "names \(stage.config.readIDs.sorted().joined(separator: ","))",
            "includeSecondary \(stage.config.includeSecondary) excludeDuplicates \(stage.config.excludeDuplicates)",
            "output \(stage.config.outputDirectory.path) \(stage.config.outputBaseName)",
            "missing \(stage.missing) \(stage.message ?? "nil")",
        ].map(masked), Self.selectedConfig)
        XCTAssertEqual(files(), Self.selectedFiles)
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertEqual(try describe(record), Self.selectedRecord)
    }

    // MARK: - Today's values

    private static let regionConfig: [String] = [
        "bam <root>/evidence/sample.bam",
        "index <root>/evidence/sample.bam.bai",
        "reference nil",
        "regions virus:11-15 fallbackToAll false",
        "minMapQ 20 excludedFlags 2308",
        "readGroups rg1,rg2 deduplicate false",
        "output <root>/out selected-region",
    ]
    private static let regionFiles: [String] = [
        "selected-region.lungfishfastq/.lungfish-provenance.json",
        "selected-region.lungfishfastq/extraction-metadata.json",
        "selected-region.lungfishfastq/provenance/bundle.lungfish-provenance.json",
        "selected-region.lungfishfastq/selected-region.fastq",
    ]
    private static let regionRecord: [String] = [
        "workflow lungfish alignment read extraction <app version>",
        "tool Lungfish.app <app version> kind app",
        "argv Lungfish.app alignment extract-region virus 10 15",
        "replay nil",
        "explicit ",
        "defaults ",
        "resolved missingSequenceMessage={\"type\":\"null\"} pairedEnd={\"type\":\"boolean\",\"value\":false} publicationMode={\"type\":\"string\",\"value\":\"hidden-sibling-directory-rename-with-rollback\"} readCount={\"type\":\"integer\",\"value\":2} recordsWithoutSequence={\"type\":\"integer\",\"value\":0} stagingToFinalMapping={\"type\":\"dictionary\",\"value\":{\"<root>/staging-selected-region/selected-region.fastq\":{\"type\":\"string\",\"value\":\"<root>/out/selected-region.lungfishfastq/selected-region.fastq\"}}}",
        "runtime <app version>",
        "file input nil <root>/evidence/sample.bam",
        "file input nil <root>/evidence/sample.bam.bai",
        "file output fastq <root>/out/selected-region.lungfishfastq/selected-region.fastq",
        "file output json <root>/out/selected-region.lungfishfastq/extraction-metadata.json",
        "output <root>/out/selected-region.lungfishfastq/selected-region.fastq",
        "step samtools samtools 1.23.1 /managed/samtools fastq -o <root>/staging-selected-region/selected-region.fastq <root>/staging-selected-region/filtered.bam",
        "step lungfish alignment extraction publisher <app version> Lungfish.app alignment extract publish --destination <root>/out/selected-region.lungfishfastq",
        "end completed exit 0 stderr tool-note",
    ]
    private static let selectedConfig: [String] = [
        "bam <root>/evidence/sample.bam",
        "names read-1,read-2",
        "includeSecondary false excludeDuplicates false",
        "output <root>/out S1_virus_selected_2reads",
        "missing 1 1 selected alignment record(s) did not contain sequence.",
    ]
    private static let selectedFiles: [String] = [
        "S1_virus_selected_2reads.lungfishfastq/.lungfish-provenance.json",
        "S1_virus_selected_2reads.lungfishfastq/S1_virus_selected_2reads.fastq",
        "S1_virus_selected_2reads.lungfishfastq/extraction-metadata.json",
        "S1_virus_selected_2reads.lungfishfastq/provenance/bundle.lungfish-provenance.json",
    ]
    private static let selectedRecord: [String] = [
        "workflow lungfish alignment read extraction <app version>",
        "tool Lungfish.app <app version> kind app",
        "argv Lungfish.app alignment extract-selected-reads",
        "replay nil",
        "explicit ",
        "defaults ",
        "resolved missingSequenceMessage={\"type\":\"string\",\"value\":\"1 selected alignment record(s) did not contain sequence.\"} pairedEnd={\"type\":\"boolean\",\"value\":false} publicationMode={\"type\":\"string\",\"value\":\"hidden-sibling-directory-rename-with-rollback\"} readCount={\"type\":\"integer\",\"value\":2} recordsWithoutSequence={\"type\":\"integer\",\"value\":1} stagingToFinalMapping={\"type\":\"dictionary\",\"value\":{\"<root>/staging-S1_virus_selected_2reads/S1_virus_selected_2reads.fastq\":{\"type\":\"string\",\"value\":\"<root>/out/S1_virus_selected_2reads.lungfishfastq/S1_virus_selected_2reads.fastq\"}}}",
        "runtime <app version>",
        "file input nil <root>/evidence/sample.bam",
        "file input nil <root>/evidence/sample.bam.bai",
        "file output fastq <root>/out/S1_virus_selected_2reads.lungfishfastq/S1_virus_selected_2reads.fastq",
        "file output json <root>/out/S1_virus_selected_2reads.lungfishfastq/extraction-metadata.json",
        "output <root>/out/S1_virus_selected_2reads.lungfishfastq/S1_virus_selected_2reads.fastq",
        "step samtools samtools 1.23.1 /managed/samtools fastq -o <root>/staging-S1_virus_selected_2reads/S1_virus_selected_2reads.fastq <root>/staging-S1_virus_selected_2reads/filtered.bam",
        "step lungfish alignment extraction publisher <app version> Lungfish.app alignment extract publish --destination <root>/out/S1_virus_selected_2reads.lungfishfastq",
        "end completed exit 0 stderr tool-note",
    ]
}
