// ViralReconLongReadDerivativeTests.swift - Viral Recon expects a derivative of a long-read bundle as single reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.42 M2, BIO ruling test T6 (Q7). The expectation the wizard and a prepared run show reads the
// recorded platform before the manifest, so a paired or mixed child of an Oxford Nanopore or PacBio bundle is
// expected as single reads, as `ReadSetResolver.plan` reads it, not split into R1 and R2.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class ViralReconLongReadDerivativeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "viral-recon-long-read-child")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private var imports: URL { root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true) }

    private func makeBundle(_ name: String, files: [String], platform: SequencingPlatform?) throws -> URL {
        let bundle = imports.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for file in files {
            let url = bundle.appendingPathComponent(file)
            try Data("@r1\nACGT\n+\nIIII\n".utf8).write(to: url)
            if let platform {
                FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: platform), for: url)
            }
        }
        return bundle
    }

    private func decision(for bundle: URL) -> ViralReconReadPairingDecision {
        ViralReconReadPairing.decision(for: ViralReconSample(
            sampleName: "child", sourceBundleURL: bundle, fastqURLs: [bundle], barcode: nil, sequencingSummaryURL: nil
        ))
    }

    func testFullPairedChildOfAnOxfordNanoporeRootIsSingleReads() throws {
        let parent = try makeBundle("ont", files: ["reads.fastq"], platform: .oxfordNanopore)
        let child = try makeBundle("ont-paired", files: ["sample_R1.fastq", "sample_R2.fastq"], platform: nil)
        let operation = FASTQDerivativeOperation(kind: .deduplicate)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "ont-paired",
                parentBundleRelativePath: "@/Imports/\(parent.lastPathComponent)",
                rootBundleRelativePath: "@/Imports/\(parent.lastPathComponent)",
                rootFASTQFilename: "reads.fastq",
                payload: .fullPaired(r1Filename: "sample_R1.fastq", r2Filename: "sample_R2.fastq"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 2, baseCount: 8),
                pairingMode: .interleaved,
                sequenceFormat: .fastq
            ),
            in: child
        )

        let expected = decision(for: child)

        XCTAssertEqual(expected.layout, .singleEnd)
        XCTAssertNotEqual(expected.handling, .splitToR1R2)
        XCTAssertTrue(
            expected.reason.hasPrefix("The bundle records Oxford Nanopore reads, which are never paired."),
            expected.reason
        )
    }

    func testFullMixedChildOfAPacBioRootIsSingleReads() throws {
        let parent = try makeBundle("pacbio", files: ["reads.fastq"], platform: .pacbio)
        let child = try makeBundle(
            "pacbio-merged",
            files: ["merged.fastq", "unmerged_R1.fastq", "unmerged_R2.fastq"],
            platform: nil
        )
        let operation = FASTQDerivativeOperation(kind: .pairedEndMerge)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "pacbio-merged",
                parentBundleRelativePath: "@/Imports/\(parent.lastPathComponent)",
                rootBundleRelativePath: "@/Imports/\(parent.lastPathComponent)",
                rootFASTQFilename: "reads.fastq",
                payload: .fullMixed(ReadClassification(files: [
                    .init(filename: "merged.fastq", role: .merged, readCount: 1),
                    .init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: 1),
                    .init(filename: "unmerged_R2.fastq", role: .pairedR2, readCount: 1),
                ])),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 3, baseCount: 12),
                pairingMode: .interleaved,
                sequenceFormat: .fastq
            ),
            in: child
        )

        let expected = decision(for: child)

        XCTAssertEqual(expected.layout, .singleEnd)
        XCTAssertTrue(expected.reason.hasPrefix("The bundle records PacBio reads, which are never paired."), expected.reason)
    }
}
