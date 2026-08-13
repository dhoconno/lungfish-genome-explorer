import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class AlignmentConsensusPublicationServiceTests: XCTestCase {
    func testFASTAPublicationInstallsSidecarBeforePayloadAndRollsBackOnPayloadFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bam = root.appendingPathComponent("evidence.bam")
        let bai = root.appendingPathComponent("evidence.bam.bai")
        try Data("bam".utf8).write(to: bam); try Data("bai".utf8).write(to: bai)
        let final = root.appendingPathComponent("consensus.fasta")
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: final)
        let context = try AlignmentActionContext(
            identity: .init(workflow: "mapping", resultID: "r", sampleID: "s", evidenceID: "e"),
            alignmentURL: bam, indexURL: bai, decodingReferenceURL: nil,
            contig: "virus", contigLength: 5,
            alignmentSnapshot: .init(url: bam, byteCount: 3, sha256: try ProvenanceFileHasher.sha256(of: bam)),
            indexSnapshot: .init(url: bai, byteCount: 3, sha256: try ProvenanceFileHasher.sha256(of: bai)),
            decodingReferenceSnapshot: nil,
            filters: .init(minimumDepth: 1, minimumMapQ: 0, minimumBaseQuality: 0, excludedFlags: 0x904, readGroups: []),
            outputCapability: .userSelectedDestination, sourceReads: .bamFallback,
            presentationLabel: "s virus"
        )
        let scientific = AlignmentConsensusRequest(chromosome: "virus", start: 0, end: 5, filters: context.filters, mode: .simple, useAmbiguity: false, insertionPolicy: .omit, deletionPolicy: .n)
        var destinations: [URL] = []
        let service = AlignmentConsensusPublicationService(moveItem: { source, destination in
            destinations.append(destination)
            if destination == final { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.moveItem(at: source, to: destination)
        })

        XCTAssertThrowsError(try service.publish(.init(
            context: context,
            region: .init(scope: .wholeContig, contig: "virus", start: 0, end: 5),
            consensusRequest: scientific,
            result: .init(sequence: "NNNNN", referenceLength: 5, allLowDepth: true),
            recordName: "consensus",
            destination: .fasta(final)
        ))) { error in
            let failure = error as? AlignmentConsensusPublicationFailure
            XCTAssertEqual(failure?.attempt.stage, .payloadPublication)
            XCTAssertEqual(failure?.attempt.destinationPath, final.path)
            XCTAssertEqual(failure?.attempt.evidence.map(\.url), [bam, bai])
            XCTAssertTrue(failure?.attempt.durableLogMessage.contains("referenceFillPolicy=never") == true)
            XCTAssertTrue(failure?.attempt.durableLogMessage.contains(try! ProvenanceFileHasher.sha256(of: bam)) == true)
        }
        XCTAssertEqual(destinations, [sidecar, final])
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }

    func testWriteAndProvenanceFailuresCarryStructuredDurableAttemptRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bam = root.appendingPathComponent("evidence.bam"), bai = root.appendingPathComponent("evidence.bam.bai")
        try Data("bam".utf8).write(to: bam); try Data("bai".utf8).write(to: bai)
        let context = try AlignmentActionContext(
            identity: .init(workflow: "mapping", resultID: "r", sampleID: "s", evidenceID: "e"),
            alignmentURL: bam, indexURL: bai, decodingReferenceURL: nil, contig: "virus", contigLength: 5,
            alignmentSnapshot: .init(url: bam, byteCount: 3, sha256: try ProvenanceFileHasher.sha256(of: bam)),
            indexSnapshot: .init(url: bai, byteCount: 3, sha256: try ProvenanceFileHasher.sha256(of: bai)), decodingReferenceSnapshot: nil,
            filters: .init(minimumDepth: 3, minimumMapQ: 12, minimumBaseQuality: 7, excludedFlags: 0x904, readGroups: ["rg"]),
            outputCapability: .userSelectedDestination, sourceReads: .bamFallback, presentationLabel: "s virus"
        )
        let scientific = AlignmentConsensusRequest(chromosome: "virus", start: 0, end: 5, filters: context.filters, mode: .simple, useAmbiguity: true, insertionPolicy: .omit, deletionPolicy: .n)
        for injectedStage in [AlignmentConsensusPublicationAttempt.Stage.payloadWrite, .provenanceWrite] {
            let final = root.appendingPathComponent("\(injectedStage.rawValue).fasta")
            let service = AlignmentConsensusPublicationService(failureInjector: { stage in
                if stage == injectedStage { throw CocoaError(.fileWriteUnknown) }
            })
            XCTAssertThrowsError(try service.publish(.init(
                context: context, region: .init(scope: .wholeContig, contig: "virus", start: 0, end: 5),
                consensusRequest: scientific, result: .init(sequence: "NNNNN", referenceLength: 5, allLowDepth: true),
                recordName: "consensus", destination: .fasta(final)
            ))) { error in
                let failure = error as? AlignmentConsensusPublicationFailure
                XCTAssertEqual(failure?.attempt.stage, injectedStage)
                XCTAssertEqual(failure?.attempt.exitStatus, 1)
                XCTAssertTrue(failure?.attempt.argv.contains(final.path) == true)
                XCTAssertEqual(failure?.attempt.explicitOptions["readGroups"], "rg")
                XCTAssertEqual(failure?.attempt.explicitOptions["useAmbiguity"], "true")
                XCTAssertEqual(failure?.attempt.resolvedDefaults["lowDepthPolicy"], "N")
                XCTAssertTrue(failure?.attempt.argv.contains(bam.path) == true)
                XCTAssertTrue(failure?.attempt.argv.contains(bai.path) == true)
                XCTAssertTrue(failure?.attempt.argv.contains("--min-mapq") == true)
                XCTAssertTrue(failure?.attempt.argv.contains("--min-baseq") == true)
                XCTAssertTrue(failure?.attempt.argv.contains("--exclude-flags") == true)
                XCTAssertTrue(failure?.attempt.argv.contains("--read-group") == true)
                XCTAssertTrue(failure?.attempt.argv.contains("--caller-mode") == true)
                XCTAssertTrue(failure?.attempt.argv.contains("--use-ambiguity") == true)
                XCTAssertFalse(failure?.attempt.stderr.isEmpty ?? true)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: final).path))
        }
    }
    func testPublishesFASTAAndFinalPathOnlyCanonicalProvenance() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("consensus-publication-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bam = root.appendingPathComponent("evidence.bam")
        let index = root.appendingPathComponent("evidence.bam.bai")
        try Data("bam".utf8).write(to: bam)
        try Data("index".utf8).write(to: index)
        let finalURL = root.appendingPathComponent("consensus.fasta")
        let started = Date(timeIntervalSince1970: 100)
        let ended = Date(timeIntervalSince1970: 101)
        let execution = AlignmentConsensusExecutionRecord(
            stage: .consensus, executablePath: "/managed/samtools", executableVersion: "samtools 1.23.1",
            runtimeIdentity: "managed-native", argv: ["consensus", "-r", "virus:11-15", "/tmp/staged/filtered.bam"],
            reproducibleCommand: "/managed/samtools consensus -r virus:11-15 /tmp/staged/filtered.bam",
            inputs: [.init(path: "/tmp/staged/filtered.bam", checksumSHA256: "filtered", fileSize: 7)],
            outputs: [], readGroupFile: nil, resolvedDefaults: ["minimumDepth": "3"], exitStatus: 0,
            startedAt: started, endedAt: ended, wallTimeSeconds: 1, stderr: "caller-note"
        )
        let context = try AlignmentActionContext(
            identity: .init(workflow: "EsViritu", resultID: "run", sampleID: "S1", evidenceID: "virus"),
            alignmentURL: bam, indexURL: index, decodingReferenceURL: nil,
            contig: "virus", contigLength: 20,
            alignmentSnapshot: .init(url: bam, byteCount: 3, sha256: try ProvenanceFileHasher.sha256(of: bam)),
            indexSnapshot: .init(url: index, byteCount: 5, sha256: try ProvenanceFileHasher.sha256(of: index)),
            decodingReferenceSnapshot: nil,
            filters: .init(minimumDepth: 3, minimumMapQ: 20, minimumBaseQuality: 12, excludedFlags: 0x904, readGroups: ["rg1"]),
            outputCapability: .userSelectedDestination, sourceReads: .bamFallback,
            presentationLabel: "S1 virus"
        )
        let consensusRequest = AlignmentConsensusRequest(
            chromosome: "virus", start: 10, end: 15, filters: context.filters,
            mode: .bayesian, useAmbiguity: false, insertionPolicy: .omit, deletionPolicy: .n
        )

        let publication = try AlignmentConsensusPublicationService().publish(.init(
            context: context,
            region: .init(scope: .selectedRegion, contig: "virus", start: 10, end: 15),
            consensusRequest: consensusRequest,
            result: .init(sequence: "ANGNN", referenceLength: 5, allLowDepth: false, executionRecords: [execution]),
            recordName: "S1 virus selected consensus",
            destination: .fasta(finalURL)
        ))

        XCTAssertEqual(try String(contentsOf: finalURL, encoding: .utf8), ">S1 virus selected consensus\nANGNN\n")
        XCTAssertEqual(publication.finalURL, finalURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: publication.provenanceURL.path), publication.provenanceURL.path)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: publication.provenanceURL))
        XCTAssertEqual(envelope.output?.path, finalURL.standardizedFileURL.path)
        XCTAssertEqual(envelope.output?.checksumSHA256, try ProvenanceFileHasher.sha256(of: finalURL))
        XCTAssertEqual(envelope.options.resolvedDefaults["lowDepthPolicy"], ParameterValue.string("N"))
        XCTAssertEqual(envelope.options.resolvedDefaults["referenceFillPolicy"], ParameterValue.string("never"))
        XCTAssertEqual(envelope.options.explicit["scope"], ParameterValue.string("selectedRegion"))
        XCTAssertEqual(envelope.options.explicit["zeroBasedHalfOpen"], ParameterValue.string("virus:10-15"))
        XCTAssertEqual(envelope.options.explicit["oneBasedInclusive"], ParameterValue.string("virus:11-15"))
        XCTAssertEqual(envelope.options.explicit["readGroups"], ParameterValue.array([.string("rg1")]))
        let evidencePaths = Set(envelope.files.filter { [.input, .index].contains($0.role) }.map(\.path))
        XCTAssertEqual(evidencePaths, Set([bam.path, index.path]))
        XCTAssertFalse(envelope.output?.path.contains(".staging") == true)
        XCTAssertTrue(envelope.steps.first?.argv.contains("consensus") == true)
        XCTAssertEqual(envelope.steps.first?.stderr, "caller-note")
    }

    func testPublishesReferenceBundleAtomicallyWithEvidenceOnlyManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("consensus-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bam = root.appendingPathComponent("evidence.bam")
        let index = root.appendingPathComponent("evidence.bam.bai")
        try Data("bam".utf8).write(to: bam); try Data("index".utf8).write(to: index)
        let context = try AlignmentActionContext(
            identity: .init(workflow: "mapping", resultID: "run", sampleID: "S1", evidenceID: "virus"),
            alignmentURL: bam, indexURL: index, decodingReferenceURL: nil, contig: "virus", contigLength: 5,
            alignmentSnapshot: .init(url: bam, byteCount: 3, sha256: try ProvenanceFileHasher.sha256(of: bam)),
            indexSnapshot: .init(url: index, byteCount: 5, sha256: try ProvenanceFileHasher.sha256(of: index)),
            decodingReferenceSnapshot: nil,
            filters: .init(minimumDepth: 3, minimumMapQ: 0, minimumBaseQuality: 0, excludedFlags: 0x904, readGroups: []),
            outputCapability: .projectDerivedRoot(root), sourceReads: .bamFallback, presentationLabel: "S1 virus"
        )
        let request = AlignmentConsensusRequest(chromosome: "virus", start: 0, end: 5, filters: context.filters, mode: .simple, useAmbiguity: false, insertionPolicy: .omit, deletionPolicy: .n)
        let finalURL = root.appendingPathComponent("derived.lungfishref", isDirectory: true)

        let publication = try AlignmentConsensusPublicationService().publish(.init(
            context: context, region: .init(scope: .wholeContig, contig: "virus", start: 0, end: 5),
            consensusRequest: request, result: .init(sequence: "NNNNN", referenceLength: 5, allLowDepth: true),
            recordName: "S1 virus consensus", destination: .referenceBundle(finalURL)
        ))

        let manifest = try BundleManifest.load(from: finalURL)
        XCTAssertEqual(manifest.genome?.chromosomes.map(\.name), ["virus"])
        XCTAssertEqual(try String(contentsOf: finalURL.appendingPathComponent("genome/consensus.fasta"), encoding: .utf8), ">S1 virus consensus\nNNNNN\n")
        XCTAssertNotNil(try ProvenanceEnvelopeReader.loadCanonical(from: finalURL))
        XCTAssertEqual(publication.finalURL, finalURL.standardizedFileURL)
    }
}
