// AlignmentConsensusPublicationPinTests.swift - Today's consensus FASTA, bundle and record, before bam consensus
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A51 M2, the freeze before `lungfish-cli bam consensus` publishes the consensus of
// the viewer's Generate Consensus row (census row 27, gap alignment-consensus, QA 1). It pins, from
// the publication service the base runs in the app, the files a FASTA and a reference bundle
// destination leave and the record each one holds, read back from disk. The text names the
// scratch folder `<root>` and the writer's version `<version>`, because the base records the
// version of the host process.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow
@testable import LungfishApp

final class AlignmentConsensusPublicationPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "consensus-publication-pin")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// Evidence with known bytes, one read group and a fixed caller result for virus:11-15.
    private func request(
        to destination: AlignmentConsensusPublicationDestination
    ) throws -> AlignmentConsensusPublicationRequest {
        let evidence = root.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let bam = evidence.appendingPathComponent("sample.bam")
        let index = evidence.appendingPathComponent("sample.bam.bai")
        try Data("bam bytes".utf8).write(to: bam)
        try Data("index bytes".utf8).write(to: index)
        let filters = AlignmentConsensusFilters(
            minimumDepth: 3, minimumMapQ: 20, minimumBaseQuality: 12, excludedFlags: 0x904, readGroups: ["rg1"]
        )
        let context = try AlignmentActionContext(
            identity: .init(workflow: "mapping", resultID: "run-1", sampleID: "S1", evidenceID: "virus"),
            alignmentURL: bam, indexURL: index, decodingReferenceURL: nil,
            contig: "virus", contigLength: 20,
            alignmentSnapshot: .init(url: bam, byteCount: 9, sha256: try ProvenanceFileHasher.sha256(of: bam)),
            indexSnapshot: .init(url: index, byteCount: 11, sha256: try ProvenanceFileHasher.sha256(of: index)),
            decodingReferenceSnapshot: nil,
            filters: filters,
            outputCapability: .userSelectedDestination, sourceReads: .bamFallback,
            presentationLabel: "S1 virus"
        )
        let consensusRequest = AlignmentConsensusRequest(
            chromosome: "virus", start: 10, end: 15, filters: filters,
            mode: .bayesian, useAmbiguity: false, insertionPolicy: .omit, deletionPolicy: .n
        )
        let started = Date(timeIntervalSince1970: 100)
        let execution = AlignmentConsensusExecutionRecord(
            stage: .consensus, executablePath: "/managed/samtools", executableVersion: "samtools 1.23.1",
            runtimeIdentity: "managed-native", argv: ["consensus", "-r", "virus:11-15", "/staged/filtered.bam"],
            reproducibleCommand: "/managed/samtools consensus -r virus:11-15 /staged/filtered.bam",
            inputs: [.init(path: "/staged/filtered.bam", checksumSHA256: "filtered", fileSize: 7)],
            outputs: [], readGroupFile: nil, resolvedDefaults: ["minimumDepth": "3"], exitStatus: 0,
            startedAt: started, endedAt: started.addingTimeInterval(1), wallTimeSeconds: 1, stderr: "caller-note"
        )
        return AlignmentConsensusPublicationRequest(
            context: context,
            region: .init(scope: .selectedRegion, contig: "virus", start: 10, end: 15),
            consensusRequest: consensusRequest,
            result: .init(sequence: "ANGNN", referenceLength: 5, allLowDepth: false, executionRecords: [execution]),
            recordName: "S1 virus consensus",
            destination: destination
        )
    }

    /// The files under `folder`, relative and sorted, with the evidence left out.
    private func files(in folder: URL) -> [String] {
        let base = folder.standardizedFileURL.path + "/"
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        var paths: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = url.standardizedFileURL.path.replacingOccurrences(of: base, with: "")
            if !path.hasPrefix("evidence/") { paths.append(path) }
        }
        return paths.sorted()
    }

    /// The record's facts as lines, with the scratch folder as `<root>` and the version as `<version>`.
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
            "defaults \(try options(envelope.options.resolvedDefaults))",
            "runtime \(envelope.runtimeIdentity.appVersion ?? "nil")",
        ]
        lines += envelope.files.map { "file \($0.role) \($0.format.map { "\($0)" } ?? "nil") \($0.path)" }
        lines.append("output \(envelope.output?.path ?? "nil")")
        lines += envelope.steps.map { "step \($0.toolName) \($0.toolVersion) \($0.argv.joined(separator: " "))" }
        lines.append("end \(envelope.status.rawValue) exit \(envelope.exitStatus.map(String.init) ?? "nil") stderr \(envelope.stderr ?? "nil")")
        let rootPath = root.standardizedFileURL.path
        return lines.map {
            $0.replacingOccurrences(of: rootPath, with: "<root>")
                .replacingOccurrences(of: WorkflowRun.currentAppVersion, with: "<version>")
                .replacingOccurrences(of: #"staging-[0-9A-F-]{36}"#, with: "staging-<uuid>", options: .regularExpression)
        }
    }

    func testAFASTADestinationLeavesTheFASTAAndItsSidecarWithTodaysRecord() throws {
        let finalURL = root.appendingPathComponent("out/consensus.fasta")
        try FileManager.default.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let publication = try AlignmentConsensusPublicationService().publish(try request(to: .fasta(finalURL)))

        XCTAssertEqual(files(in: root), ["out/consensus.fasta", "out/consensus.fasta.lungfish-provenance.json"])
        XCTAssertEqual(try String(contentsOf: finalURL, encoding: .utf8), ">S1 virus consensus\nANGNN\n")
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: publication.provenanceURL))
        XCTAssertEqual(try describe(envelope), Self.fastaRecord)
    }

    func testABundleDestinationLeavesTheBundleWithTodaysManifestAndRecord() throws {
        let finalURL = root.appendingPathComponent("out/consensus.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        _ = try AlignmentConsensusPublicationService().publish(try request(to: .referenceBundle(finalURL)))

        XCTAssertEqual(files(in: root), Self.bundleFiles)
        XCTAssertEqual(
            try String(contentsOf: finalURL.appendingPathComponent("genome/consensus.fasta"), encoding: .utf8),
            ">S1 virus consensus\nANGNN\n"
        )
        XCTAssertEqual(
            try String(contentsOf: finalURL.appendingPathComponent("genome/consensus.fasta.fai"), encoding: .utf8),
            "virus\t5\t20\t5\t6\n"
        )
        let manifest = try BundleManifest.load(from: finalURL)
        XCTAssertEqual(manifest.name, "S1 virus consensus")
        XCTAssertEqual(manifest.source.assembly, "run-1")
        XCTAssertEqual(manifest.genome?.chromosomes.map(\.name), ["virus"])
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: finalURL))
        XCTAssertEqual(try describe(envelope), Self.bundleRecord)
    }

    static let bundleFiles = [
        "out/consensus.lungfishref/.lungfish-provenance.json",
        "out/consensus.lungfishref/genome/consensus.fasta",
        "out/consensus.lungfishref/genome/consensus.fasta.fai",
        "out/consensus.lungfishref/manifest.json",
    ]

    static let fastaRecord = record(
        output: "<root>/out/consensus.fasta",
        payload: "<root>/out/consensus.fasta",
        provenance: "<root>/out/consensus.fasta.lungfish-provenance.json",
        staged: "<root>/out/.consensus.fasta.staging-<uuid>"
    )

    static let bundleRecord = record(
        output: "<root>/out/consensus.lungfishref",
        payload: "<root>/out/consensus.lungfishref/genome/consensus.fasta",
        provenance: "<root>/out/consensus.lungfishref/.lungfish-provenance.json",
        staged: "<root>/out/.consensus.lungfishref.staging-<uuid>/genome/consensus.fasta"
    )

    /// Today's record of the consensus written to `output`, whose sequence sits at `payload`.
    static func record(output: String, payload: String, provenance: String, staged: String) -> [String] {
        func value(_ type: String, _ text: String) -> String { #"{"type":"\#(type)","value":\#(text)}"# }
        let argv = "Lungfish.app alignment consensus --alignment <root>/evidence/sample.bam"
            + " --index <root>/evidence/sample.bam.bai --scope selectedRegion --region virus:10-15"
            + " --min-depth 3 --min-mapq 20 --min-baseq 12 --exclude-flags 2308 --read-group rg1"
            + " --caller-mode bayesian --use-ambiguity false --insertion-policy omit --deletion-policy n"
            + " --reference-fill never --output \(output)"
        let explicit = [
            "callerMode=" + value("string", #""bayesian""#),
            "deletionPolicy=" + value("string", #""n""#),
            "excludedFlags=" + value("integer", "2308"),
            "insertionPolicy=" + value("string", #""omit""#),
            "minimumBaseQuality=" + value("integer", "12"),
            "minimumDepth=" + value("integer", "3"),
            "minimumMapQ=" + value("integer", "20"),
            "oneBasedInclusive=" + value("string", #""virus:11-15""#),
            "readGroups=" + value("array", "[" + value("string", #""rg1""#) + "]"),
            "scope=" + value("string", #""selectedRegion""#),
            "useAmbiguity=" + value("boolean", "false"),
            "zeroBasedHalfOpen=" + value("string", #""virus:10-15""#),
        ]
        let defaults = [
            "allLowDepth=" + value("boolean", "false"),
            "finalProvenancePath=" + value("string", "\"\(provenance)\""),
            "lowDepthPolicy=" + value("string", #""N""#),
            "referenceFillPolicy=" + value("string", #""never""#),
            "stagingToFinalMapping=" + value("dictionary", "{\"\(staged)\":" + value("string", "\"\(payload)\"") + "}"),
        ]
        return [
            "workflow lungfish alignment consensus <version>",
            "tool Lungfish.app <version> kind app",
            "argv \(argv)",
            "replay \(argv)",
            "explicit " + explicit.joined(separator: " "),
            "defaults " + defaults.joined(separator: " "),
            "runtime <version>",
            "file input bam <root>/evidence/sample.bam",
            "file index unknown <root>/evidence/sample.bam.bai",
            "file output fasta \(payload)",
            "output \(payload)",
            "step samtools samtools 1.23.1 /managed/samtools consensus -r virus:11-15 /staged/filtered.bam",
            "end completed exit 0 stderr caller-note",
        ]
    }
}
