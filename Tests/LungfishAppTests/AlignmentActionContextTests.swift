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

    func testDecodingReferenceURLRequiresSnapshot() {
        let cramURL = URL(fileURLWithPath: "/tmp/reads.cram")
        let craiURL = URL(fileURLWithPath: "/tmp/reads.cram.crai")
        let referenceURL = URL(fileURLWithPath: "/tmp/reference.fasta")

        XCTAssertThrowsError(try makeContext(
            alignmentURL: cramURL,
            indexURL: craiURL,
            decodingReferenceURL: referenceURL,
            decodingReferenceSnapshot: nil
        )) {
            XCTAssertEqual(
                $0 as? AlignmentActionContext.ValidationError,
                .missingDecodingReferenceSnapshot(referenceURL)
            )
        }
    }

    func testDecodingReferenceSnapshotRequiresURL() {
        let referenceURL = URL(fileURLWithPath: "/tmp/reference.fasta")

        XCTAssertThrowsError(try makeContext(
            decodingReferenceURL: nil,
            decodingReferenceSnapshot: .init(url: referenceURL, byteCount: 128, sha256: "reference")
        )) {
            XCTAssertEqual(
                $0 as? AlignmentActionContext.ValidationError,
                .unexpectedDecodingReferenceSnapshot(referenceURL)
            )
        }
    }

    func testContextIdentityAndSnapshotsAreStableAndDetectEvidenceChanges() async throws {
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
        // A fresh digest cache per test keeps this independent of other tests
        // that may have hashed these exact paths (unlikely, since they're
        // per-test temp directories, but explicit is cheap and avoids any
        // possibility of a stale cross-test cache hit).
        let digestCache = AlignmentEvidenceDigestCache()
        try await context.validateCurrentSnapshots(digestCache: digestCache)

        try Data("changed BAM".utf8).write(to: bamURL)
        do {
            try await context.validateCurrentSnapshots(digestCache: digestCache)
            XCTFail("Expected stale evidence after the BAM's contents changed")
        } catch let error as AlignmentActionContext.EvidenceError {
            XCTAssertEqual(error, .staleEvidence(bamURL))
        }
    }

    /// A cache hit must never re-hash: an identity that already has a cached
    /// digest short-circuits before the hasher runs at all.
    func testDigestCacheServesCachedDigestWithoutRehashingOnIdentityMatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("evidence.bam")
        try Data("evidence".utf8).write(to: fileURL)

        let identity = try AlignmentEvidenceFileIdentity.current(of: fileURL)
        let cache = AlignmentEvidenceDigestCache()

        var hashCallCount = 0
        let first = try await cache.digest(for: identity) {
            hashCallCount += 1
            return "digest-value"
        }
        let second = try await cache.digest(for: identity) {
            hashCallCount += 1
            return "should-not-be-called"
        }

        XCTAssertEqual(first, "digest-value")
        XCTAssertEqual(second, "digest-value")
        XCTAssertEqual(hashCallCount, 1)
        let count = await cache.cachedEntryCount()
        XCTAssertEqual(count, 1)
    }

    func testReadOnlyClassifierContextAllowsClipboardAndUsesDestinationChooser() throws {
        let context = try makeContext()

        XCTAssertTrue(context.allowsClipboardActions)
        XCTAssertEqual(context.outputCapability, .userSelectedDestination)
    }

    private func makeContext(
        alignmentURL: URL = URL(fileURLWithPath: "/tmp/reads.bam"),
        indexURL: URL = URL(fileURLWithPath: "/tmp/reads.bam.bai"),
        decodingReferenceURL: URL? = nil,
        contig: String = "chrSynthetic",
        contigLength: Int = 40,
        alignmentSnapshot: AlignmentEvidenceFileSnapshot? = nil,
        indexSnapshot: AlignmentEvidenceFileSnapshot? = nil,
        decodingReferenceSnapshot: AlignmentEvidenceFileSnapshot? = nil
    ) throws -> AlignmentActionContext {
        try AlignmentActionContext(
            identity: .init(workflow: "EsViritu", resultID: "run-1", sampleID: "sample-1", evidenceID: "chrSynthetic"),
            alignmentURL: alignmentURL,
            indexURL: indexURL,
            decodingReferenceURL: decodingReferenceURL,
            contig: contig,
            contigLength: contigLength,
            alignmentSnapshot: alignmentSnapshot ?? .init(url: alignmentURL, byteCount: 512, sha256: "abc"),
            indexSnapshot: indexSnapshot ?? .init(url: indexURL, byteCount: 96, sha256: "def"),
            decodingReferenceSnapshot: decodingReferenceSnapshot,
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
