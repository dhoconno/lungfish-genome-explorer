// AlignmentActionContextTests.swift - Immutable alignment action evidence tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO
import LungfishWorkflow

final class AlignmentActionContextTests: XCTestCase {
    func testContextRejectsInvalidEvidenceShape() {
        let bamURL = URL(fileURLWithPath: "/tmp/reads.bam")
        let baiURL = URL(fileURLWithPath: "/tmp/reads.bam.bai")

        XCTAssertThrowsError(try makeContext(contig: ""))
        XCTAssertThrowsError(try makeContext(contigLength: 0))
        XCTAssertThrowsError(try makeContext(
            alignmentSnapshot: .init(url: URL(fileURLWithPath: "/tmp/other.bam"), byteCount: 512, sha256: "abc")
        ))
        XCTAssertThrowsError(try makeContext(indexURL: URL(fileURLWithPath: "/tmp/reads.index")))
        XCTAssertNoThrow(try makeContext(alignmentURL: bamURL, indexURL: baiURL))
    }

    func testContextIdentityAndSnapshotsAreStableAndDetectEvidenceChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bamURL = directory.appendingPathComponent("reads.bam")
        let baiURL = directory.appendingPathComponent("reads.bam.bai")
        try Data("bam".utf8).write(to: bamURL)
        try Data("bai".utf8).write(to: baiURL)

        let context = try makeContext(
            alignmentURL: bamURL,
            indexURL: baiURL,
            alignmentSnapshot: snapshot(for: bamURL),
            indexSnapshot: snapshot(for: baiURL)
        )
        let equalContext = try makeContext(
            alignmentURL: bamURL,
            indexURL: baiURL,
            alignmentSnapshot: snapshot(for: bamURL),
            indexSnapshot: snapshot(for: baiURL)
        )

        XCTAssertEqual(context.identity, equalContext.identity)
        XCTAssertEqual(context, equalContext)
        XCTAssertNoThrow(try context.validateCurrentSnapshots())

        try Data("changed BAM".utf8).write(to: bamURL)
        XCTAssertThrowsError(try context.validateCurrentSnapshots()) {
            XCTAssertEqual($0 as? AlignmentActionContext.EvidenceError, .staleEvidence(bamURL))
        }
    }

    func testReadOnlyClassifierContextAllowsClipboardAndUsesDestinationChooser() throws {
        let context = try makeContext()

        XCTAssertTrue(context.allowsClipboardActions)
        XCTAssertEqual(context.outputCapability, .userSelectedDestination)
    }

    private func makeContext(
        alignmentURL: URL = URL(fileURLWithPath: "/tmp/reads.bam"),
        indexURL: URL = URL(fileURLWithPath: "/tmp/reads.bam.bai"),
        contig: String = "chrSynthetic",
        contigLength: Int = 40,
        alignmentSnapshot: AlignmentEvidenceFileSnapshot? = nil,
        indexSnapshot: AlignmentEvidenceFileSnapshot? = nil
    ) throws -> AlignmentActionContext {
        try AlignmentActionContext(
            identity: .init(workflow: "EsViritu", resultID: "run-1", sampleID: "sample-1", evidenceID: "chrSynthetic"),
            alignmentURL: alignmentURL,
            indexURL: indexURL,
            decodingReferenceURL: nil,
            contig: contig,
            contigLength: contigLength,
            alignmentSnapshot: alignmentSnapshot ?? .init(url: alignmentURL, byteCount: 512, sha256: "abc"),
            indexSnapshot: indexSnapshot ?? .init(url: indexURL, byteCount: 96, sha256: "def"),
            decodingReferenceSnapshot: nil,
            filters: .init(minimumDepth: 3, minimumMapQ: 20, minimumBaseQuality: 12,
                           excludedFlags: 0x904, readGroups: []),
            outputCapability: .userSelectedDestination,
            sourceReads: .bamFallback,
            presentationLabel: "sample-1 chrSynthetic"
        )
    }

    private func snapshot(for url: URL) -> AlignmentEvidenceFileSnapshot {
        .init(
            url: url,
            byteCount: try! ProvenanceFileHasher.fileSize(of: url),
            sha256: try! ProvenanceFileHasher.sha256(of: url)
        )
    }
}
