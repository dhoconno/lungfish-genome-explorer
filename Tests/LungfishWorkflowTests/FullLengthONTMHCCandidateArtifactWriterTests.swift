import CryptoKit
import Foundation
import LungfishIO
import XCTest
@testable import LungfishWorkflow

final class FullLengthONTMHCCandidateArtifactWriterTests: XCTestCase {
    func testPublishesReciprocalEvidenceAndCanonicalCandidateArtifacts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = try await fixture.write(observations: fixture.observations)

        let commands = try fixture.commands()
        let minimap = try XCTUnwrap(commands.first)
        XCTAssertEqual(Array(minimap.prefix(10)), [
            "minimap2", "-a", "--eqx", "--cs=long", "-x", "asm20", "-t", "14", "-N", "100",
        ])
        XCTAssertEqual(minimap[minimap.count - 3], "--secondary=yes")
        XCTAssertEqual(minimap[minimap.count - 2], fixture.referenceFASTAURL.path)
        XCTAssertTrue(minimap.last?.hasSuffix("/deduplicated_unmatched_clusters.fasta") == true)
        XCTAssertEqual(commands.dropFirst().map { Array($0.prefix(2)) }, [
            ["samtools", "view"], ["samtools", "sort"], ["samtools", "index"],
            ["samtools", "quickcheck"], ["samtools", "idxstats"], ["samtools", "view"],
        ])

        XCTAssertEqual(try fastaHeaders(result.candidateFASTAURL), [fixture.novelID, fixture.extensionID])
        XCTAssertEqual(try fastaHeaders(result.unnameableFASTAURL), [fixture.unnameableID])
        let candidate = try JSONDecoder().decode(
            ONTMHCCandidateAllelesDocument.self,
            from: Data(contentsOf: result.candidateJSONURL)
        )
        let unnameable = try JSONDecoder().decode(
            ONTMHCUnnameableClustersDocument.self,
            from: Data(contentsOf: result.unnameableJSONURL)
        )
        XCTAssertEqual(candidate.schemaVersion, 1)
        XCTAssertEqual(result.toolVersions.map(\.toolName), ["minimap2", "samtools"])
        XCTAssertEqual(result.toolVersions.map(\.version), ["2.28-fake", "samtools 1.21-fake"])
        XCTAssertTrue(result.commandRecords.allSatisfy { $0.toolVersion?.isEmpty == false })
        XCTAssertFalse(result.runtimeIdentity.executablePath.isEmpty)
        XCTAssertEqual(candidate.candidates.map(\.stableClusterID), [fixture.novelID, fixture.extensionID])
        XCTAssertEqual(candidate.candidates.map(\.provisionalName), [
            "Mafa-A1*018:01:01:01_5nt_nov", "Mafa-B*001:01_ext",
        ])
        XCTAssertEqual(unnameable.clusters.map(\.stableClusterID), [fixture.unnameableID])
        XCTAssertEqual(unnameable.clusters.first?.reason, .noAlignment)
        XCTAssertEqual(unnameable.inputs, candidate.inputs)
        XCTAssertEqual(unnameable.evidence, candidate.evidence)
        XCTAssertEqual(result.manifest.reciprocalEvidence?.bam.path, "artifacts/alignments/unmatched-to-reference.bam")
        XCTAssertEqual(result.manifest.candidateJSON?.path, "candidate-alleles.json")
        for reference in result.allArtifactReferences {
            let url = fixture.outputURL.appendingPathComponent(reference.path)
            XCTAssertEqual(reference.sha256, try sha256(url))
            XCTAssertEqual(reference.sizeBytes, try fileSize(url))
        }

        let bytes = try Data(contentsOf: result.candidateJSONURL)
        XCTAssertEqual(bytes, try canonicalizedJSON(bytes))
    }

    func testStableIDsAndArtifactsAreInvariantToSampleOrderAndKeepLabelCollisionsSeparate() async throws {
        let first = try Fixture()
        defer { first.remove() }
        let second = try Fixture()
        defer { second.remove() }
        let collisionSequence = String(repeating: "A", count: 1_194) + "CCCCCC"
        let collisionID = stableID(collisionSequence)
        let collision = FullLengthONTMHCCandidateSequenceObservation(
            sampleID: "sample-c", readGroupID: "sample-c", sourceClusterID: "source-c",
            clusterReadCount: 9, sequence: collisionSequence, genotypingEvidence: []
        )
        first.additionalSAM = "\(collisionID)\t0\tref-genomic\t1\t60\t1194=5X1=\t*\t0\t0\t*\t*\tNM:i:5\tAS:i:1189\n"
        second.additionalSAM = first.additionalSAM

        let forward = try await first.write(observations: first.observations + [collision])
        let reverse = try await second.write(observations: Array(([collision] + second.observations).reversed()))

        let left = try JSONDecoder().decode(ONTMHCCandidateAllelesDocument.self, from: Data(contentsOf: forward.candidateJSONURL))
        let right = try JSONDecoder().decode(ONTMHCCandidateAllelesDocument.self, from: Data(contentsOf: reverse.candidateJSONURL))
        XCTAssertEqual(left.candidates.map(\.stableClusterID), right.candidates.map(\.stableClusterID))
        XCTAssertEqual(
            left.observations.map { "\($0.stableClusterID)|\($0.sampleID)" },
            right.observations.map { "\($0.stableClusterID)|\($0.sampleID)" }
        )
        let collisionLabel = "Mafa-A1*018:01:01:01_5nt_nov"
        XCTAssertEqual(left.candidates.filter { $0.provisionalName == collisionLabel }.count, 2)
        XCTAssertEqual(Set(left.candidates.filter { $0.provisionalName == collisionLabel }.map(\.stableClusterID)).count, 2)
    }

    func testFailureDoesNotReplacePreviouslyPublishedCandidateTruth() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try await fixture.write(observations: fixture.observations)
        let oldCandidate = try Data(contentsOf: first.candidateJSONURL)
        try Data("sort".utf8).write(to: fixture.toolsURL.appendingPathComponent("fail-command"))

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.write(observations: fixture.observations)
        }
        XCTAssertEqual(try Data(contentsOf: first.candidateJSONURL), oldCandidate)
        XCTAssertEqual(try fastaHeaders(first.candidateFASTAURL), [fixture.novelID, fixture.extensionID])
    }

    private func fastaHeaders(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
            line.first == ">" ? String(line.dropFirst()).split(separator: " ").first.map(String.init) : nil
        }
    }

    private func stableID(_ sequence: String) -> String {
        FullLengthONTMHCCandidateArtifactWriter.stableClusterID(for: sequence)
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value
    }

    private func canonicalizedJSON(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([0x0a])
    }
}

private extension FullLengthONTMHCCandidateArtifactWriterTests {
    final class Fixture {
        let rootURL: URL
        let outputURL: URL
        let workURL: URL
        let toolsURL: URL
        let referenceFASTAURL: URL
        var additionalSAM = ""

        let novelSequence = String(repeating: "A", count: 1_200)
        let extensionSequence = String(repeating: "C", count: 1_050)
        let unnameableSequence = String(repeating: "G", count: 900)
        var novelID: String { FullLengthONTMHCCandidateArtifactWriter.stableClusterID(for: novelSequence) }
        var extensionID: String { FullLengthONTMHCCandidateArtifactWriter.stableClusterID(for: extensionSequence) }
        var unnameableID: String { FullLengthONTMHCCandidateArtifactWriter.stableClusterID(for: unnameableSequence) }

        var observations: [FullLengthONTMHCCandidateSequenceObservation] { [
            .init(sampleID: "sample-b", readGroupID: "sample-b", sourceClusterID: "b1", clusterReadCount: 7, sequence: novelSequence, genotypingEvidence: []),
            .init(sampleID: "sample-a", readGroupID: "sample-a", sourceClusterID: "a1", clusterReadCount: 5, sequence: novelSequence, genotypingEvidence: []),
            .init(sampleID: "sample-a", readGroupID: "sample-a", sourceClusterID: "a2", clusterReadCount: 11, sequence: extensionSequence, genotypingEvidence: []),
            .init(sampleID: "sample-z", readGroupID: "sample-z", sourceClusterID: "z1", clusterReadCount: 3, sequence: unnameableSequence, genotypingEvidence: []),
        ] }

        init() throws {
            rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            outputURL = rootURL.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
            workURL = rootURL.appendingPathComponent("work", isDirectory: true)
            toolsURL = rootURL.appendingPathComponent("tools", isDirectory: true)
            referenceFASTAURL = rootURL.appendingPathComponent("reference.fa")
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: toolsURL, withIntermediateDirectories: true)
            try Data(">ref-genomic\n\(String(repeating: "A", count: 1_200))\n>ref-cdna\n\(String(repeating: "C", count: 1_000))\n".utf8).write(to: referenceFASTAURL)
            try writeExecutable(Self.minimapScript, to: toolsURL.appendingPathComponent("minimap2"))
            try writeExecutable(Self.samtoolsScript, to: toolsURL.appendingPathComponent("samtools"))
        }

        func write(observations: [FullLengthONTMHCCandidateSequenceObservation]) async throws -> FullLengthONTMHCCandidateArtifactResult {
            try Data(samText.utf8).write(to: toolsURL.appendingPathComponent("sam-template"), options: .atomic)
            let writer = FullLengthONTMHCCandidateArtifactWriter(executableDirectoryURL: toolsURL)
            return try await writer.write(.init(
                observations: observations,
                referenceAlleleFASTAURL: referenceFASTAURL,
                referenceRecords: [
                    .init(sequenceID: "ref-genomic", alleleName: "Mafa-A1*018:01:01:01", locus: "Mafa-A1", moleculeClass: .genomicDNA, classEvidence: .annotatedMetadata, sequenceLength: 1_200),
                    .init(sequenceID: "ref-cdna", alleleName: "Mafa-B*001:01", locus: "Mafa-B", moleculeClass: .cDNA, classEvidence: .annotatedMetadata, sequenceLength: 1_000),
                ],
                genotypingEvidence: nil,
                threads: 14,
                outputDirectoryURL: outputURL,
                workDirectoryURL: workURL
            ))
        }

        func commands() throws -> [[String]] {
            let text = try String(contentsOf: toolsURL.appendingPathComponent("commands.log"), encoding: .utf8)
            return text.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
                .filter { $0.first != "minimap2-version" && $0.first != "samtools-version" }
        }

        func remove() { try? FileManager.default.removeItem(at: rootURL) }

        private var samText: String {
            """
            @HD\tVN:1.6\tSO:coordinate
            @SQ\tSN:ref-genomic\tLN:1200
            @SQ\tSN:ref-cdna\tLN:1000
            \(novelID)\t0\tref-genomic\t1\t60\t595=5X600=\t*\t0\t0\t*\t*\tNM:i:5\tAS:i:1190
            \(extensionID)\t0\tref-cdna\t1\t55\t500=50I500=\t*\t0\t0\t*\t*\tNM:i:50\tAS:i:1000
            \(additionalSAM)
            """
        }

        private func writeExecutable(_ text: String, to url: URL) throws {
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        private static let minimapScript = #"""
        #!/bin/sh
        tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
        if [ "$1" = "--version" ]; then
          printf 'minimap2-version\n' >> "$tool_dir/commands.log"
          printf '2.28-fake\n'
          exit 0
        fi
        printf 'minimap2' >> "$tool_dir/commands.log"
        for arg in "$@"; do printf '\t%s' "$arg" >> "$tool_dir/commands.log"; done
        printf '\n' >> "$tool_dir/commands.log"
        cat "$tool_dir/sam-template"
        """#

        private static let samtoolsScript = #"""
        #!/bin/sh
        tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
        if [ "$1" = "--version" ]; then
          printf 'samtools-version\n' >> "$tool_dir/commands.log"
          printf 'samtools 1.21-fake\n'
          exit 0
        fi
        printf 'samtools' >> "$tool_dir/commands.log"
        for arg in "$@"; do printf '\t%s' "$arg" >> "$tool_dir/commands.log"; done
        printf '\n' >> "$tool_dir/commands.log"
        if [ -f "$tool_dir/fail-command" ] && [ "$(cat "$tool_dir/fail-command")" = "$1" ]; then
          printf 'forced failure\n' >&2
          exit 23
        fi
        case "$1" in
          view)
            if [ "$2" = "-b" ]; then cp "$5" "$4"; else cat "$3"; fi ;;
          sort) cp "$4" "$3" ;;
          index) printf 'index\n' > "$3" ;;
          quickcheck) test -s "$2" && test -s "$2.bai" ;;
          idxstats) printf 'ref-genomic\t1200\t1\t0\n' ;;
        esac
        """#
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
