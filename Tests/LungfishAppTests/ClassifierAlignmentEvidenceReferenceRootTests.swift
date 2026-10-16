// ClassifierAlignmentEvidenceReferenceRootTests.swift - Managed-database references and indexed record reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishKit

/// A classifier's BAM and index must always live inside the final result, but a
/// reference need not: EsViritu aligns against a managed database's pangenome
/// FASTA that is shared across results and never copied into one. These tests
/// pin exactly how far containment is relaxed, and pin that the record lookup on
/// a large FASTA goes through a `.fai` rather than reading the whole file.
final class ClassifierAlignmentEvidenceReferenceRootTests: XCTestCase {

    // MARK: - Containment

    func testReferenceInsideTheManagedDatabaseRootIsAccepted() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:chr1\tLN:4\n" },
            indexQuery: { _, _, _ in },
            additionalReferenceRoots: [fixture.databaseRoot]
        )

        let result = try await validator.validate(fixture.request(referenceURL: fixture.managedFASTA))

        XCTAssertEqual(result.reference.sequence, "ACTG")
        XCTAssertEqual(result.reference.status, .validatedStructural)
    }

    func testReferenceInAnUnrelatedDirectoryIsStillRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:chr1\tLN:4\n" },
            indexQuery: { _, _, _ in },
            additionalReferenceRoots: [fixture.databaseRoot]
        )

        await XCTAssertThrowsErrorAsync(
            try await validator.validate(fixture.request(referenceURL: fixture.strayFASTA))
        ) { error in
            XCTAssertEqual(
                error as? ClassifierAlignmentEvidenceValidator.Error,
                .evidenceOutsideFinalResult(fixture.strayFASTA)
            )
        }
    }

    /// Relaxing the reference rule must not relax the evidence rule: a BAM in the
    /// managed database root is still outside the result.
    func testBAMInTheManagedDatabaseRootIsStillRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let strayBAM = fixture.databaseRoot.appendingPathComponent("evidence.bam")
        try Data([0x42]).write(to: strayBAM)

        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:chr1\tLN:4\n" },
            indexQuery: { _, _, _ in },
            additionalReferenceRoots: [fixture.databaseRoot]
        )

        await XCTAssertThrowsErrorAsync(
            try await validator.validate(fixture.request(referenceURL: nil, bamURL: strayBAM))
        ) { error in
            XCTAssertEqual(
                error as? ClassifierAlignmentEvidenceValidator.Error,
                .evidenceOutsideFinalResult(strayBAM)
            )
        }
    }

    /// A sibling directory sharing the database root's name prefix is outside it.
    func testSiblingPrefixOfTheDatabaseRootIsNotContained() throws {
        let root = URL(fileURLWithPath: "/tmp/lungfish/databases")
        XCTAssertTrue(ClassifierAlignmentEvidenceValidator.isContained(
            URL(fileURLWithPath: "/tmp/lungfish/databases/esviritu/db.fna"), inAnyOf: [root]
        ))
        XCTAssertFalse(ClassifierAlignmentEvidenceValidator.isContained(
            URL(fileURLWithPath: "/tmp/lungfish/databases-copy/esviritu/db.fna"), inAnyOf: [root]
        ))
        XCTAssertFalse(ClassifierAlignmentEvidenceValidator.isContained(
            URL(fileURLWithPath: "/tmp/lungfish/db.fna"), inAnyOf: [root]
        ))
    }

    // MARK: - Indexed record reads

    /// A FASTA large enough to matter must be read through a `.fai`, and the index
    /// must be written beside it so the next lookup reuses it rather than
    /// rescanning hundreds of megabytes.
    func testLargeFASTARecordIsReadViaAnIndexThatIsBuiltOnceAndReused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EsVirituIndexedFASTA-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Comfortably past the indexed-read threshold, with the target record last
        // so a scanning implementation would have to walk the whole file.
        let filler = String(repeating: "ACGT", count: 16)
        let fillerLines = (0..<(ClassifierAlignmentEvidenceValidator.indexedReadThreshold / 65))
            .map { ">filler\($0)\n\(filler)" }
            .joined(separator: "\n")
        let fastaURL = directory.appendingPathComponent("virus_pathogen_database.fna")
        try (fillerLines + "\n>NC_TARGET.1 some description\nACGTACGTAC\nGTAA\n")
            .write(to: fastaURL, atomically: true, encoding: .utf8)

        let faiURL = URL(fileURLWithPath: fastaURL.path + ".fai")
        XCTAssertFalse(FileManager.default.fileExists(atPath: faiURL.path))

        let record = try ClassifierAlignmentEvidenceValidator.readExactFASTARecord(
            at: fastaURL, named: "NC_TARGET.1"
        )
        XCTAssertEqual(record, "ACGTACGTACGTAA")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: faiURL.path),
            "the index must be written beside the FASTA so later lookups reuse it"
        )
        let firstIndexContents = try Data(contentsOf: faiURL)

        // A second lookup reuses the index rather than rebuilding it.
        let again = try ClassifierAlignmentEvidenceValidator.readExactFASTARecord(
            at: fastaURL, named: "NC_TARGET.1"
        )
        XCTAssertEqual(again, "ACGTACGTACGTAA")
        XCTAssertEqual(try Data(contentsOf: faiURL), firstIndexContents)

        // A record that is not in the file stays unavailable rather than returning
        // some neighbouring sequence.
        XCTAssertThrowsError(
            try ClassifierAlignmentEvidenceValidator.readExactFASTARecord(at: fastaURL, named: "NC_ABSENT.1")
        )
    }

    /// A `.fai` left behind by an earlier, differently-laid-out FASTA must not be
    /// trusted: stale offsets would hand the viewer a neighbouring sequence and
    /// call it the reference. The index is rebuilt instead.
    func testStaleIndexIsRebuiltRatherThanTrusted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EsVirituStaleIndex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let filler = String(repeating: "ACGT", count: 16)
        let fillerLines = (0..<(ClassifierAlignmentEvidenceValidator.indexedReadThreshold / 65))
            .map { ">filler\($0)\n\(filler)" }
            .joined(separator: "\n")
        let fastaURL = directory.appendingPathComponent("virus_pathogen_database.fna")
        try (fillerLines + "\n>NC_TARGET.1 pathogen\nACGTACGTAC\nGTAA\n")
            .write(to: fastaURL, atomically: true, encoding: .utf8)

        // An index whose offset points into unrelated filler bases.
        let faiURL = URL(fileURLWithPath: fastaURL.path + ".fai")
        try "NC_TARGET.1\t14\t40\t10\t11\n".write(to: faiURL, atomically: true, encoding: .utf8)

        let record = try ClassifierAlignmentEvidenceValidator.readExactFASTARecord(
            at: fastaURL, named: "NC_TARGET.1"
        )
        XCTAssertEqual(record, "ACGTACGTACGTAA", "a stale index must be rebuilt, not followed")
    }

    /// Small result-local references keep the exact-scan path, including its
    /// rejection of a duplicated record name.
    func testSmallFASTAKeepsExactScanSemantics() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EsVirituSmallFASTA-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let unique = directory.appendingPathComponent("unique.fa")
        try ">chr1\nACTG\n>chr2\nTTTT\n".write(to: unique, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try ClassifierAlignmentEvidenceValidator.readExactFASTARecord(at: unique, named: "chr1"),
            "ACTG"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: unique.path + ".fai"),
            "small references must not litter the result directory with indexes"
        )

        let duplicated = directory.appendingPathComponent("duplicated.fa")
        try ">chr1\nACTG\n>chr1 again\nTTTT\n".write(to: duplicated, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(
            try ClassifierAlignmentEvidenceValidator.readExactFASTARecord(at: duplicated, named: "chr1")
        )
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let resultRoot: URL
        let databaseRoot: URL
        let bam: URL
        let index: URL
        let managedFASTA: URL
        let strayFASTA: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("EsVirituReferenceRoot-\(UUID().uuidString)", isDirectory: true)
            resultRoot = root.appendingPathComponent("esviritu-batch-abc", isDirectory: true)
            databaseRoot = root.appendingPathComponent("databases", isDirectory: true)
            let managedDirectory = databaseRoot
                .appendingPathComponent("esviritu/esviritu-viral-db/v3.2.4", isDirectory: true)
            let strayDirectory = root.appendingPathComponent("elsewhere", isDirectory: true)
            for directory in [resultRoot, managedDirectory, strayDirectory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            bam = resultRoot.appendingPathComponent("evidence.bam")
            index = resultRoot.appendingPathComponent("evidence.bam.bai")
            try Data([0x42, 0x41, 0x4D]).write(to: bam)
            try Data([0x42, 0x41, 0x49]).write(to: index)
            managedFASTA = managedDirectory.appendingPathComponent("virus_pathogen_database.fna")
            strayFASTA = strayDirectory.appendingPathComponent("virus_pathogen_database.fna")
            for url in [managedFASTA, strayFASTA] {
                try ">chr1\nACTG\n".write(to: url, atomically: true, encoding: .utf8)
            }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        func request(referenceURL: URL?, bamURL: URL? = nil) throws -> ClassifierAlignmentEvidenceRequest {
            try ClassifierAlignmentEvidenceRequest(
                workflow: .esViritu,
                resultIdentity: .init(stableID: "result", finalResultURL: resultRoot, provenanceID: "esviritu:test"),
                bamURL: bamURL ?? bam,
                index: .init(url: index, kind: .bai),
                sample: .init(canonicalID: "sample-a"),
                contig: .init(name: "chr1", expectedLength: 4),
                referenceCandidate: referenceURL.map {
                    .init(fastaURL: $0, recordName: "chr1", expectedLength: 4)
                },
                presentation: .init(
                    workflowLabel: "EsViritu",
                    resultLabel: "result",
                    sampleLabel: "sample-a",
                    contigLabel: "chr1"
                )
            )
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in }
) async {
    do { _ = try await expression(); XCTFail("Expected error") }
    catch { handler(error) }
}

extension ClassifierAlignmentEvidenceReferenceRootTests {
    /// Repeated snapshots of an unchanged file must not re-hash it; a rewrite
    /// (new size or mtime) must produce a fresh digest.
    func testSnapshotDigestCacheReusesUntilTheFileChanges() throws {
        let cache = ClassifierAlignmentEvidenceValidator.SnapshotDigestCache()
        var computes = 0
        let mtime = Date(timeIntervalSince1970: 1_000)
        let make: () throws -> ClassifierAlignmentEvidenceFileSnapshot = {
            computes += 1
            return .init(size: 10, sha256: "digest-\(computes)")
        }
        let first = try cache.snapshot(path: "/db/ref.fna", size: 10, mtime: mtime, probe: "p1", compute: make)
        let second = try cache.snapshot(path: "/db/ref.fna", size: 10, mtime: mtime, probe: "p1", compute: make)
        XCTAssertEqual(computes, 1)
        XCTAssertEqual(first, second)
        _ = try cache.snapshot(path: "/db/ref.fna", size: 10, mtime: mtime.addingTimeInterval(5), probe: "p1", compute: make)
        XCTAssertEqual(computes, 2, "an mtime change must invalidate the cached digest")
        _ = try cache.snapshot(path: "/db/ref.fna", size: 11, mtime: mtime.addingTimeInterval(5), probe: "p1", compute: make)
        XCTAssertEqual(computes, 3, "a size change must invalidate the cached digest")
        _ = try cache.snapshot(path: "/db/ref.fna", size: 11, mtime: mtime.addingTimeInterval(5), probe: "p2", compute: make)
        XCTAssertEqual(computes, 4, "a content-edge change must invalidate the cached digest even at identical size and mtime")
    }
}
