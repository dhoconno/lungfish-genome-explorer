import XCTest
@testable import LungfishIO

final class FASTQPBAAArtifactStoreTests: XCTestCase {
    func testStorePersistsPBAAArtifactInsideFASTQBundleAndFindsStrictCompatibleArtifact() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let bundleURL = root.appendingPathComponent("DL46.lungfishfastq", isDirectory: true)
        let fastqURL = bundleURL.appendingPathComponent("DL46.fastq")
        let guideURL = root.appendingPathComponent("guide.fasta")
        let preparedURL = root.appendingPathComponent("prepared.fastq")
        let passedURL = root.appendingPathComponent("DL46_passed_cluster_sequences.fasta")
        let rawURL = root.appendingPathComponent("raw-pbaa", isDirectory: true)
        let provenanceURL = root.appendingPathComponent("pbaa-clustering-provenance.json")

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rawURL, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)
        try ">guide\nACGT\n".write(to: guideURL, atomically: true, encoding: .utf8)
        try "@r1\nACGT\n+\nIIII\n".write(to: preparedURL, atomically: true, encoding: .utf8)
        try ">Cluster1_ReadCount-12\nACGT\n".write(to: passedURL, atomically: true, encoding: .utf8)
        try "read_id\tcluster\nr1\tCluster1\n".write(
            to: rawURL.appendingPathComponent("DL46_read_info.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "{\"workflow\":\"pbaa\"}\n".write(to: provenanceURL, atomically: true, encoding: .utf8)

        let signature = try FASTQPBAAArtifactSignature(
            sourceFASTQ: .fingerprint(url: bundleURL, displayPath: bundleURL.path),
            preparedReads: .fingerprint(url: preparedURL, displayPath: preparedURL.path),
            guide: .fingerprint(url: guideURL, displayPath: guideURL.path),
            preprocessing: FASTQPBAAPreprocessingSignature(
                orientReference: nil,
                forwardPrimer: nil,
                reversePrimer: nil,
                minimumLength: 2_000,
                maximumLength: 4_000
            ),
            clustering: FASTQPBAAClusteringSignature(
                pbaaToolVersion: "1.2.0",
                workflowSchemaVersion: "pbaa-cluster/1",
                seed: 1984,
                extraArguments: ["--min-cluster-read-count", "3"],
                extraArgumentsText: "--min-cluster-read-count 3",
                pbaaContainerReference: "quay.io/biocontainers/pbaa:1.2.0--h9ee0642_0",
                pbaaContainerExpectedDigest: "sha256:pbaa",
                samtoolsContainerReference: "quay.io/biocontainers/samtools:1.23.1--ha83d96e_0",
                samtoolsContainerExpectedDigest: "sha256:samtools"
            )
        )

        let stored = try FASTQPBAAArtifactStore.saveArtifact(
            FASTQPBAAArtifactWriteRequest(
                bundleURL: bundleURL,
                id: "dl46-guide-a",
                displayName: "DL46 pbAA",
                sampleName: "DL46",
                signature: signature,
                passedConsensusFASTAURL: passedURL,
                rawOutputDirectoryURL: rawURL,
                provenanceURL: provenanceURL,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )

        XCTAssertTrue(stored.artifactDirectoryURL.path.hasPrefix(bundleURL.path))
        XCTAssertEqual(stored.passedConsensusFASTAURL.lastPathComponent, "passed_cluster_sequences.fasta")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.passedConsensusFASTAURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.provenanceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.rawOutputDirectoryURL?.path ?? ""))

        let artifacts = try FASTQPBAAArtifactStore.artifacts(in: bundleURL)
        XCTAssertEqual(artifacts.map(\.manifest.id), ["dl46-guide-a"])
        XCTAssertEqual(artifacts.first?.manifest.signature, signature)
        XCTAssertEqual(artifacts.first?.manifest.clusterCount, 1)
        XCTAssertEqual(artifacts.first?.manifest.clusteredReadCount, 12)

        let compatible = try FASTQPBAAArtifactStore.compatibleArtifacts(
            in: bundleURL,
            matching: signature
        )
        XCTAssertEqual(compatible.map(\.manifest.id), ["dl46-guide-a"])
    }

    func testCompatibilityRejectsMissingProvenanceChecksumMismatchAndChangedGuide() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let bundleURL = root.appendingPathComponent("DL47.lungfishfastq", isDirectory: true)
        let fastqURL = bundleURL.appendingPathComponent("DL47.fastq")
        let guideURL = root.appendingPathComponent("guide-a.fasta")
        let otherGuideURL = root.appendingPathComponent("guide-b.fasta")
        let preparedURL = root.appendingPathComponent("prepared.fastq")
        let passedURL = root.appendingPathComponent("passed.fasta")
        let provenanceURL = root.appendingPathComponent("provenance.json")

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)
        try ">guide-a\nACGT\n".write(to: guideURL, atomically: true, encoding: .utf8)
        try ">guide-b\nTGCA\n".write(to: otherGuideURL, atomically: true, encoding: .utf8)
        try "@r1\nACGT\n+\nIIII\n".write(to: preparedURL, atomically: true, encoding: .utf8)
        try ">Cluster1_ReadCount-3\nACGT\n".write(to: passedURL, atomically: true, encoding: .utf8)
        try "{\"workflow\":\"pbaa\"}\n".write(to: provenanceURL, atomically: true, encoding: .utf8)

        let signature = try makeSignature(
            bundleURL: bundleURL,
            preparedURL: preparedURL,
            guideURL: guideURL
        )
        let stored = try FASTQPBAAArtifactStore.saveArtifact(
            FASTQPBAAArtifactWriteRequest(
                bundleURL: bundleURL,
                id: "dl47-guide-a",
                displayName: "DL47 pbAA",
                sampleName: "DL47",
                signature: signature,
                passedConsensusFASTAURL: passedURL,
                rawOutputDirectoryURL: nil,
                provenanceURL: provenanceURL
            )
        )

        try FileManager.default.removeItem(at: stored.provenanceURL)
        XCTAssertEqual(
            try FASTQPBAAArtifactStore.compatibility(of: stored, matching: signature),
            .missingProvenance
        )

        try "{\"workflow\":\"pbaa\"}\n".write(to: stored.provenanceURL, atomically: true, encoding: .utf8)
        try ">Cluster1_ReadCount-3\nTGCA\n".write(to: stored.passedConsensusFASTAURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try FASTQPBAAArtifactStore.compatibility(of: stored, matching: signature),
            .checksumMismatch
        )

        try ">Cluster1_ReadCount-3\nACGT\n".write(to: stored.passedConsensusFASTAURL, atomically: true, encoding: .utf8)
        let changedGuideSignature = try makeSignature(
            bundleURL: bundleURL,
            preparedURL: preparedURL,
            guideURL: otherGuideURL
        )
        XCTAssertEqual(
            try FASTQPBAAArtifactStore.compatibility(of: stored, matching: changedGuideSignature),
            .differentGuide
        )
    }

    func testCompatibilityIgnoresPreparedReadDisplayPathWhenContentMatches() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let bundleURL = root.appendingPathComponent("DL48.lungfishfastq", isDirectory: true)
        let fastqURL = bundleURL.appendingPathComponent("DL48.fastq")
        let guideURL = root.appendingPathComponent("guide.fasta")
        let firstPreparedURL = root.appendingPathComponent("first-run/prepared.fastq")
        let secondPreparedURL = root.appendingPathComponent("second-run/prepared.fastq")
        let passedURL = root.appendingPathComponent("passed.fasta")
        let provenanceURL = root.appendingPathComponent("provenance.json")

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: firstPreparedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondPreparedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@r1\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)
        try ">guide\nACGT\n".write(to: guideURL, atomically: true, encoding: .utf8)
        try "@r1\nACGT\n+\nIIII\n".write(to: firstPreparedURL, atomically: true, encoding: .utf8)
        try "@r1\nACGT\n+\nIIII\n".write(to: secondPreparedURL, atomically: true, encoding: .utf8)
        try ">Cluster1_ReadCount-3\nACGT\n".write(to: passedURL, atomically: true, encoding: .utf8)
        try "{\"workflow\":\"pbaa\"}\n".write(to: provenanceURL, atomically: true, encoding: .utf8)

        let savedSignature = try makeSignature(
            bundleURL: bundleURL,
            preparedURL: firstPreparedURL,
            guideURL: guideURL
        )
        let stored = try FASTQPBAAArtifactStore.saveArtifact(
            FASTQPBAAArtifactWriteRequest(
                bundleURL: bundleURL,
                id: "dl48-guide-a",
                displayName: "DL48 pbAA",
                sampleName: "DL48",
                signature: savedSignature,
                passedConsensusFASTAURL: passedURL,
                rawOutputDirectoryURL: nil,
                provenanceURL: provenanceURL
            )
        )
        let rerunSignature = try makeSignature(
            bundleURL: bundleURL,
            preparedURL: secondPreparedURL,
            guideURL: guideURL
        )

        XCTAssertNotEqual(savedSignature.preparedReads.displayPath, rerunSignature.preparedReads.displayPath)
        XCTAssertEqual(
            try FASTQPBAAArtifactStore.compatibility(of: stored, matching: rerunSignature),
            .compatible
        )
    }

    private func makeSignature(
        bundleURL: URL,
        preparedURL: URL,
        guideURL: URL
    ) throws -> FASTQPBAAArtifactSignature {
        try FASTQPBAAArtifactSignature(
            sourceFASTQ: .fingerprint(url: bundleURL, displayPath: bundleURL.path),
            preparedReads: .fingerprint(url: preparedURL, displayPath: preparedURL.path),
            guide: .fingerprint(url: guideURL, displayPath: guideURL.path),
            preprocessing: FASTQPBAAPreprocessingSignature(
                orientReference: nil,
                forwardPrimer: nil,
                reversePrimer: nil,
                minimumLength: 2_000,
                maximumLength: 4_000
            ),
            clustering: FASTQPBAAClusteringSignature(
                pbaaToolVersion: "1.2.0",
                workflowSchemaVersion: "pbaa-cluster/1",
                seed: 1984,
                extraArguments: [],
                extraArgumentsText: "",
                pbaaContainerReference: "pbaa",
                pbaaContainerExpectedDigest: "sha256:pbaa",
                samtoolsContainerReference: "samtools",
                samtoolsContainerExpectedDigest: "sha256:samtools"
            )
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastq-pbaa-artifacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
