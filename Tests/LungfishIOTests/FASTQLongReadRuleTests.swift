// FASTQLongReadRuleTests.swift - The long-read rule and the platform lookup it reads, in LungfishIO
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.42 M2, BIO ruling tests T1 and T2. The rule moved out of `ReadSetResolver` into
// `FASTQLongReadRule`, with the same three reads in the same order and the same walk through each parent.

import XCTest
@testable import LungfishIO
import LungfishTestSupport

final class FASTQLongReadRuleTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastq-long-read-rule-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var imports: URL { folder.appendingPathComponent("Project.lungfish/Imports", isDirectory: true) }

    private static let reads = "@r1\nACGT\n+\nIIII\n@r1\nACGT\n+\nIIII\n"

    /// A bundle holding `reads.fastq`, whose sidecar records `platform` when given.
    private func makeBundle(_ name: String, platform: SequencingPlatform?) throws -> URL {
        let bundle = imports.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastq = bundle.appendingPathComponent("reads.fastq")
        try Data(Self.reads.utf8).write(to: fastq)
        if let platform {
            FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: platform), for: fastq)
        }
        return bundle
    }

    /// A deduplicate child of `parent` whose own sidecar records nothing.
    private func makeChild(_ name: String, of parent: URL) throws -> URL {
        let child = try makeBundle(name, platform: nil)
        let operation = FASTQDerivativeOperation(kind: .deduplicate)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: name,
                parentBundleRelativePath: "@/Imports/\(parent.lastPathComponent)",
                rootBundleRelativePath: "@/Imports/\(parent.lastPathComponent)",
                rootFASTQFilename: "reads.fastq",
                payload: .full(fastqFilename: "reads.fastq"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .countsOnlyFixture(readCount: 2, baseCount: 8),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: child
        )
        return child
    }

    // MARK: - T1

    func testOnlyOxfordNanoporeAndPacBioAreLongReads() {
        for platform in SequencingPlatform.allCases {
            XCTAssertEqual(
                FASTQLongReadRule.isLongRead(platform),
                platform == .oxfordNanopore || platform == .pacbio,
                platform.rawValue
            )
        }
        XCTAssertFalse(FASTQLongReadRule.isLongRead(nil))
    }

    // MARK: - T2

    func testChildFindsThePlatformThroughItsParent() throws {
        let root = try makeBundle("ont", platform: .oxfordNanopore)
        let child = try makeChild("ont-subset", of: root)

        XCTAssertEqual(FASTQLongReadRule.ancestors(of: child).map(\.lastPathComponent), ["ont.lungfishfastq"])
        XCTAssertEqual(FASTQLongReadRule.recordedPlatform(of: child), .oxfordNanopore)
    }

    func testGrandchildFindsThePlatformThroughTwoParents() throws {
        let root = try makeBundle("ont", platform: .oxfordNanopore)
        let child = try makeChild("ont-subset", of: root)
        let grandchild = try makeChild("ont-subset-trim", of: child)

        XCTAssertEqual(
            FASTQLongReadRule.ancestors(of: grandchild).map(\.lastPathComponent),
            ["ont-subset.lungfishfastq", "ont.lungfishfastq"]
        )
        XCTAssertEqual(FASTQLongReadRule.recordedPlatform(of: grandchild), .oxfordNanopore)
    }

    func testPrimaryFileSidecarOutranksTheBundleOwnSidecar() throws {
        let bundle = try makeBundle("pacbio", platform: .pacbio)
        FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: .illumina), for: bundle)
        XCTAssertEqual(FASTQMetadataStore.load(for: bundle)?.sequencingPlatform, .illumina)

        XCTAssertEqual(FASTQLongReadRule.recordedPlatform(of: bundle), .pacbio)
    }

    func testBundleOwnSidecarAnswersWhenItsFileRecordsNone() throws {
        let bundle = try makeBundle("plain", platform: nil)
        FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: .oxfordNanopore), for: bundle)

        XCTAssertEqual(FASTQLongReadRule.recordedPlatform(of: bundle), .oxfordNanopore)
    }

    func testRootWithNoSidecarRecordsNoPlatform() throws {
        let bundle = try makeBundle("plain", platform: nil)

        XCTAssertTrue(FASTQLongReadRule.ancestors(of: bundle).isEmpty)
        XCTAssertNil(FASTQLongReadRule.recordedPlatform(of: bundle))
    }
}
