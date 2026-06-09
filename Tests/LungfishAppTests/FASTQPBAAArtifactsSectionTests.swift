// FASTQPBAAArtifactsSectionTests.swift - Inspector pbAA artifact section tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class FASTQPBAAArtifactsSectionTests: XCTestCase {
    func testLoadDisplaysSavedPBAAArtifactsFromFASTQBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQPBAAArtifactsSection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("DL46.lungfishfastq", isDirectory: true)
        let fastqURL = bundleURL.appendingPathComponent("DL46.fastq")
        let preparedURL = root.appendingPathComponent("prepared.fastq")
        let guideURL = root.appendingPathComponent("guide.fasta")
        let passedURL = root.appendingPathComponent("passed.fasta")
        let provenanceURL = root.appendingPathComponent("pbaa-provenance.json")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)
        try "@r1\nACGT\n+\nIIII\n".write(to: preparedURL, atomically: true, encoding: .utf8)
        try ">guide\nACGT\n".write(to: guideURL, atomically: true, encoding: .utf8)
        try ">Cluster1_ReadCount-12\nACGT\n>Cluster2_ReadCount-8\nTGCA\n".write(
            to: passedURL,
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
                extraArguments: [],
                extraArgumentsText: "",
                pbaaContainerReference: "pbaa",
                pbaaContainerExpectedDigest: "sha256:pbaa",
                samtoolsContainerReference: "samtools",
                samtoolsContainerExpectedDigest: "sha256:samtools"
            )
        )
        try FASTQPBAAArtifactStore.saveArtifact(FASTQPBAAArtifactWriteRequest(
            bundleURL: bundleURL,
            id: "guide-a",
            displayName: "DL46 guide A clusters",
            sampleName: "DL46",
            signature: signature,
            passedConsensusFASTAURL: passedURL,
            rawOutputDirectoryURL: nil,
            provenanceURL: provenanceURL,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))

        let viewModel = FASTQPBAAArtifactsSectionViewModel()
        viewModel.load(from: bundleURL)

        XCTAssertTrue(viewModel.hasArtifacts)
        XCTAssertEqual(viewModel.artifacts.count, 1)
        XCTAssertEqual(viewModel.artifacts[0].displayName, "DL46 guide A clusters")
        XCTAssertEqual(viewModel.artifacts[0].clusterCountText, "2 clusters")
        XCTAssertEqual(viewModel.artifacts[0].clusteredReadCountText, "20 clustered reads")
        XCTAssertEqual(viewModel.artifacts[0].guideDisplayPath, guideURL.path)
    }
}
