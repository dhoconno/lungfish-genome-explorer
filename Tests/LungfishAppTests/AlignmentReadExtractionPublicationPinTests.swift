// AlignmentReadExtractionPublicationPinTests.swift - The region and selected-read bundles and records extract reads publishes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A51 M3 (census row 22, QA 1). The viewer's Extract Reads in Selected Region and
// Extract Selected Reads run `lungfish-cli extract reads` with the evidence's index. For the command
// each row records, parsed as the leaf parses it, this pins what the run hands its stager, the files
// the bundle destination leaves and the record the publisher writes, read back from disk. The runs
// go through `ExtractReadsSubcommand.extractEvidence(_:stages:)` with stand-in stagers that stage a
// known FASTQ with one samtools record, so the pin needs no tool. The text names the scratch folder
// `<root>`, `LungfishAppVersion.short` `<app version>` and each staging UUID `<uuid>`.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class AlignmentReadExtractionPublicationPinTests: XCTestCase {
    /// What the run handed its stagers.
    private actor Staged {
        private(set) var region: BAMRegionExtractionConfig?
        private(set) var alignment: (config: ReadIDBAMExtractionConfig, missing: Int, message: String?)?
        private(set) var sources: ReadIDExtractionConfig?
        func record(region config: BAMRegionExtractionConfig) { region = config }
        func record(alignment config: ReadIDBAMExtractionConfig, missing: Int, message: String?) { alignment = (config, missing, message) }
        func record(sources config: ReadIDExtractionConfig) { sources = config }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "read-extraction-pin")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("out"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// Evidence with known bytes and every filter set, as the viewer holds it.
    private func context(sourceReads: AlignmentSourceReadResolution = .bamFallback) throws -> AlignmentActionContext {
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
            outputCapability: .userSelectedDestination, sourceReads: sourceReads,
            presentationLabel: "S1 virus"
        )
    }

    /// The reads the user selected: two with sequence and a secondary record of the first without.
    private let reads = [
        AlignedRead(name: "read-2", flag: 0, chromosome: "virus", position: 12, mapq: 60, cigar: [], sequence: "TTGA", qualities: [40, 40, 40, 40]),
        AlignedRead(name: "read-1", flag: 0, chromosome: "virus", position: 10, mapq: 60, cigar: [], sequence: "ACGT", qualities: [40, 40, 40, 40]),
        AlignedRead(name: "read-1", flag: 256, chromosome: "virus", position: 20, mapq: 0, cigar: [], sequence: "*", qualities: []),
    ]

    /// What a stager hands back: two reads staged as `<name>.fastq` with the samtools record that wrote them.
    nonisolated private static func transaction(
        in root: URL, named name: String, missing: Int = 0, message: String? = nil
    ) throws -> AlignmentReadExtractionTransaction {
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

    /// The run the row's command asks for, parsed as the leaf parses it.
    private func leafInvocation(_ invocation: AlignmentReadExtractionInvocation) throws -> AlignmentReadExtractionInvocation {
        let arguments = ViewerViewController.alignmentReadExtractionCLIArguments(invocation)
        return try ExtractReadsSubcommand.parse(Array(arguments.dropFirst(2))).evidenceInvocation
    }

    /// The selected reads' run, with the names file the route writes beside the bundle before its row begins.
    private func selectedReadsInvocation(context: AlignmentActionContext, name: String) throws -> AlignmentReadExtractionInvocation {
        let destination = AlignmentReadExtractionPublicationDestination.bundle(root.appendingPathComponent("out/\(name).lungfishfastq"))
        let namesFile = AlignmentReadExtractionInvocation.readNamesFileURL(forBundle: destination.finalURL)
        try AlignmentReadExtractionInvocation.writeReadNames(reads.map(\.name), to: namesFile)
        return try leafInvocation(ViewerViewController.selectedReadsExtractionInvocation(
            context: context, records: reads, namesFile: namesFile, destination: destination, outputBaseName: name
        ))
    }

    private func masked(_ text: String) -> String {
        text.replacingOccurrences(of: root.standardizedFileURL.path, with: "<root>")
            .replacingOccurrences(of: LungfishAppVersion.short, with: "<app version>")
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

    func testARegionExtractionStagesTheEvidenceFiltersAndPublishesTheBundleAndRecord() async throws {
        let root = self.root!
        let staged = Staged()
        var stages = ExtractReadsEvidenceStages()
        // The evidence holds stand-in bytes, so the header the region check reads is a stand-in too.
        stages.header = { _ in "@SQ\tSN:virus\tLN:40\n" }
        stages.region = { config in
            await staged.record(region: config)
            return try Self.transaction(in: root, named: "selected-region")
        }
        let invocation = try leafInvocation(ViewerViewController.alignmentRegionExtractionInvocation(
            context: try context(), region: .init(scope: .selectedRegion, contig: "virus", start: 10, end: 15),
            destination: .bundle(root.appendingPathComponent("out/selected-region.lungfishfastq")), outputBaseName: "selected-region"
        ))

        let result = try await ExtractReadsSubcommand.extractEvidence(invocation, stages: stages)

        let region = await staged.region
        let config = try XCTUnwrap(region)
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

    func testASelectedReadsExtractionStagesTheNamesAndPublishesTheBundleAndRecord() async throws {
        let root = self.root!
        let staged = Staged()
        var stages = ExtractReadsEvidenceStages()
        stages.alignment = { config, missing, message in
            await staged.record(alignment: config, missing: missing, message: message)
            return try Self.transaction(in: root, named: "S1_virus_selected_2reads", missing: missing, message: message)
        }
        let invocation = try selectedReadsInvocation(context: try context(), name: "S1_virus_selected_2reads")

        let result = try await ExtractReadsSubcommand.extractEvidence(invocation, stages: stages)

        let alignment = await staged.alignment
        let stage = try XCTUnwrap(alignment)
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

    /// The run takes selected reads from the evidence's original FASTQs, with both mates of each
    /// pair, when the evidence names them, and from the alignment only otherwise.
    func testSelectedReadsComeFromTheOriginalFASTQsWhenTheEvidenceNamesThem() async throws {
        let root = self.root!
        let staged = Staged()
        var stages = ExtractReadsEvidenceStages()
        stages.sources = { config, _, _ in
            await staged.record(sources: config)
            return try Self.transaction(in: root, named: "S1_sources")
        }
        stages.alignment = { config, missing, message in
            await staged.record(alignment: config, missing: missing, message: message)
            return try Self.transaction(in: root, named: "S1_sources")
        }
        let source = root.appendingPathComponent("evidence/S1_R1.fastq")
        let context = try context(sourceReads: .sourceFASTQs([source]))
        try "@read-1\nACGT\n+\nIIII\n".write(to: source, atomically: true, encoding: .utf8)

        _ = try await ExtractReadsSubcommand.extractEvidence(try selectedReadsInvocation(context: context, name: "S1_sources"), stages: stages)

        let sources = await staged.sources
        let config = try XCTUnwrap(sources)
        XCTAssertEqual(config.sourceFASTQs.map(\.path), [source.standardizedFileURL.path])
        XCTAssertEqual(config.readIDs, ["read-1", "read-2"])
        XCTAssertTrue(config.keepReadPairs)
        let tookTheAlignment = await staged.alignment != nil
        XCTAssertFalse(tookTheAlignment, "the run takes no read from the alignment when the evidence names its FASTQs")
    }

    // MARK: - The values

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
        "tool lungfish-cli <app version> kind cli",
        "argv lungfish-cli extract reads --by-region --bam <root>/evidence/sample.bam --index <root>/evidence/sample.bam.bai --region virus:11-15 --min-mapq 20 --exclude-flags 2308 --read-group rg1 --read-group rg2 --bundle-name selected-region --output <root>/out/selected-region.lungfishfastq",
        "replay lungfish-cli extract reads --by-region --bam <root>/evidence/sample.bam --index <root>/evidence/sample.bam.bai --region virus:11-15 --min-mapq 20 --exclude-flags 2308 --read-group rg1 --read-group rg2 --bundle-name selected-region --output <root>/out/selected-region.lungfishfastq",
        "explicit alignment={\"type\":\"file\",\"value\":\"<root>/evidence/sample.bam\"} decodingReference={\"type\":\"null\"} excludedFlags={\"type\":\"integer\",\"value\":2308} index={\"type\":\"file\",\"value\":\"<root>/evidence/sample.bam.bai\"} minimumMapQ={\"type\":\"integer\",\"value\":20} output={\"type\":\"file\",\"value\":\"<root>/out/selected-region.lungfishfastq\"} readGroups={\"type\":\"array\",\"value\":[{\"type\":\"string\",\"value\":\"rg1\"},{\"type\":\"string\",\"value\":\"rg2\"}]} readsName={\"type\":\"string\",\"value\":\"selected-region\"} regionsOneBasedInclusive={\"type\":\"array\",\"value\":[{\"type\":\"string\",\"value\":\"virus:11-15\"}]}",
        "defaults ",
        "resolved missingSequenceMessage={\"type\":\"null\"} pairedEnd={\"type\":\"boolean\",\"value\":false} publicationMode={\"type\":\"string\",\"value\":\"hidden-sibling-directory-rename-with-rollback\"} readCount={\"type\":\"integer\",\"value\":2} recordsWithoutSequence={\"type\":\"integer\",\"value\":0} stagingToFinalMapping={\"type\":\"dictionary\",\"value\":{\"<root>/staging-selected-region/selected-region.fastq\":{\"type\":\"string\",\"value\":\"<root>/out/selected-region.lungfishfastq/selected-region.fastq\"}}}",
        "runtime <app version>",
        "file input nil <root>/evidence/sample.bam",
        "file input nil <root>/evidence/sample.bam.bai",
        "file output fastq <root>/out/selected-region.lungfishfastq/selected-region.fastq",
        "file output json <root>/out/selected-region.lungfishfastq/extraction-metadata.json",
        "output <root>/out/selected-region.lungfishfastq/selected-region.fastq",
        "step samtools samtools 1.23.1 /managed/samtools fastq -o <root>/staging-selected-region/selected-region.fastq <root>/staging-selected-region/filtered.bam",
        "step lungfish alignment extraction publisher <app version> Lungfish Genome Explorer alignment extract publish --destination <root>/out/selected-region.lungfishfastq",
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
        "S1_virus_selected_2reads.read-names.txt",
    ]
    private static let selectedRecord: [String] = [
        "workflow lungfish alignment read extraction <app version>",
        "tool lungfish-cli <app version> kind cli",
        "argv lungfish-cli extract reads --by-id --ids <root>/out/S1_virus_selected_2reads.read-names.txt --bam <root>/evidence/sample.bam --index <root>/evidence/sample.bam.bai --records-without-sequence 1 --bundle-name S1_virus_selected_2reads --output <root>/out/S1_virus_selected_2reads.lungfishfastq",
        "replay lungfish-cli extract reads --by-id --ids <root>/out/S1_virus_selected_2reads.read-names.txt --bam <root>/evidence/sample.bam --index <root>/evidence/sample.bam.bai --records-without-sequence 1 --bundle-name S1_virus_selected_2reads --output <root>/out/S1_virus_selected_2reads.lungfishfastq",
        "explicit alignment={\"type\":\"file\",\"value\":\"<root>/evidence/sample.bam\"} decodingReference={\"type\":\"null\"} excludeDuplicates={\"type\":\"boolean\",\"value\":false} includeSecondary={\"type\":\"boolean\",\"value\":false} index={\"type\":\"file\",\"value\":\"<root>/evidence/sample.bam.bai\"} output={\"type\":\"file\",\"value\":\"<root>/out/S1_virus_selected_2reads.lungfishfastq\"} readNames={\"type\":\"file\",\"value\":\"<root>/out/S1_virus_selected_2reads.read-names.txt\"} readsName={\"type\":\"string\",\"value\":\"S1_virus_selected_2reads\"} recordsWithoutSequence={\"type\":\"integer\",\"value\":1} sourceFASTQs={\"type\":\"array\",\"value\":[]}",
        "defaults ",
        "resolved missingSequenceMessage={\"type\":\"string\",\"value\":\"1 selected alignment record(s) did not contain sequence.\"} pairedEnd={\"type\":\"boolean\",\"value\":false} publicationMode={\"type\":\"string\",\"value\":\"hidden-sibling-directory-rename-with-rollback\"} readCount={\"type\":\"integer\",\"value\":2} recordsWithoutSequence={\"type\":\"integer\",\"value\":1} stagingToFinalMapping={\"type\":\"dictionary\",\"value\":{\"<root>/staging-S1_virus_selected_2reads/S1_virus_selected_2reads.fastq\":{\"type\":\"string\",\"value\":\"<root>/out/S1_virus_selected_2reads.lungfishfastq/S1_virus_selected_2reads.fastq\"}}}",
        "runtime <app version>",
        "file input nil <root>/evidence/sample.bam",
        "file input nil <root>/evidence/sample.bam.bai",
        "file input nil <root>/out/S1_virus_selected_2reads.read-names.txt",
        "file output fastq <root>/out/S1_virus_selected_2reads.lungfishfastq/S1_virus_selected_2reads.fastq",
        "file output json <root>/out/S1_virus_selected_2reads.lungfishfastq/extraction-metadata.json",
        "output <root>/out/S1_virus_selected_2reads.lungfishfastq/S1_virus_selected_2reads.fastq",
        "step samtools samtools 1.23.1 /managed/samtools fastq -o <root>/staging-S1_virus_selected_2reads/S1_virus_selected_2reads.fastq <root>/staging-S1_virus_selected_2reads/filtered.bam",
        "step lungfish alignment extraction publisher <app version> Lungfish Genome Explorer alignment extract publish --destination <root>/out/S1_virus_selected_2reads.lungfishfastq",
        "end completed exit 0 stderr tool-note",
    ]
}
