// PreparedAlignmentAttachmentServiceTests.swift - Tests for prepared alignment attach commit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class PreparedAlignmentAttachmentServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreparedAlignmentAttachmentServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// R3-R3ML-18: attach() re-reads the manifest from disk immediately before commit
    /// and must reject an outputTrackName collision against that freshly-read
    /// manifest, even when the collision was NOT present in whatever snapshot an
    /// earlier upfront caller-side check (e.g. BAMPrimerTrimSubcommand's pre-pipeline
    /// name check) may have seen. This simulates the TOCTOU window directly: seed the
    /// on-disk manifest with a same-named track *after* constructing the attachment
    /// request (standing in for "a concurrent process added a same-named track while
    /// this caller's pipeline was running"), then call attach() and assert it is
    /// rejected rather than silently creating a second track with a duplicate name.
    func testAttachRejectsNameCollisionAgainstFreshlyReadManifestAtCommitTime() async throws {
        let bundleURL = try makeMinimalBundle(named: "test-bundle")
        let existingTrack = AlignmentTrackInfo(
            id: "aln_existing",
            name: "duplicate-name",
            sourcePath: "alignments/existing.bam",
            indexPath: "alignments/existing.bam.bai"
        )

        let (stagedBAM, stagedIndex) = try makeStagedArtifacts(in: tempDir)
        let request = PreparedAlignmentAttachmentRequest(
            bundleURL: bundleURL,
            stagedBAMURL: stagedBAM,
            stagedIndexURL: stagedIndex,
            outputTrackID: "aln_new",
            outputTrackName: "duplicate-name",
            relativeDirectory: "alignments"
        )

        // Simulate a concurrent writer adding the same-named track to the on-disk
        // manifest *after* this caller already constructed its request (standing in
        // for the TOCTOU window between an earlier upfront check and this commit).
        var manifest = try BundleManifest.load(from: bundleURL)
        manifest = manifest.addingAlignmentTrack(existingTrack)
        try manifest.save(to: bundleURL)

        let service = PreparedAlignmentAttachmentService(
            metadataCollector: StubPreparedAlignmentMetadataCollector()
        )

        do {
            _ = try await service.attach(request: request)
            XCTFail("Expected attach to reject the name collision")
        } catch PreparedAlignmentAttachmentError.duplicateTrackName(let name) {
            XCTAssertEqual(name, "duplicate-name")
        } catch {
            XCTFail("Expected duplicateTrackName, got \(error)")
        }

        // The bundle must be left with exactly the pre-existing track -- no
        // second, duplicately-named track was attached, and no artifacts were
        // promoted into the bundle for the rejected attach.
        let finalManifest = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(finalManifest.alignments.map(\.id), ["aln_existing"])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: bundleURL.appendingPathComponent("alignments/aln_new.sorted.bam").path
            )
        )
    }

    /// Regression guard: a genuinely unique name must still succeed normally.
    func testAttachSucceedsWhenNameIsUnique() async throws {
        let bundleURL = try makeMinimalBundle(named: "test-bundle-2")
        let (stagedBAM, stagedIndex) = try makeStagedArtifacts(in: tempDir)
        let request = PreparedAlignmentAttachmentRequest(
            bundleURL: bundleURL,
            stagedBAMURL: stagedBAM,
            stagedIndexURL: stagedIndex,
            outputTrackID: "aln_unique",
            outputTrackName: "unique-name",
            relativeDirectory: "alignments"
        )

        let service = PreparedAlignmentAttachmentService(
            metadataCollector: StubPreparedAlignmentMetadataCollector()
        )

        let result = try await service.attach(request: request)
        XCTAssertEqual(result.trackInfo.name, "unique-name")

        let finalManifest = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(finalManifest.alignments.map(\.name), ["unique-name"])
    }

    func testAttachPublishesWholeFileUnmappedCountFromFlagstat() async throws {
        let bundleURL = try makeMinimalBundle(named: "whole-file-counts")
        let (stagedBAM, stagedIndex) = try makeStagedArtifacts(in: tempDir)
        let request = PreparedAlignmentAttachmentRequest(
            bundleURL: bundleURL,
            stagedBAMURL: stagedBAM,
            stagedIndexURL: stagedIndex,
            outputTrackID: "aln_counts",
            outputTrackName: "counts",
            relativeDirectory: "alignments"
        )
        let collector = StubPreparedAlignmentMetadataCollector(
            idxstatsOutput: """
            PX392161\t2280\t2\t0
            PX392163\t2182\t23\t0
            *\t0\t0\t5633894
            """,
            flagstatOutput: """
            5633919 + 0 in total (QC-passed reads + QC-failed reads)
            25 + 0 mapped (0.00% : N/A)
            """
        )

        let result = try await PreparedAlignmentAttachmentService(
            metadataCollector: collector
        ).attach(request: request)

        XCTAssertEqual(result.trackInfo.mappedReadCount, 25)
        XCTAssertEqual(result.trackInfo.unmappedReadCount, 5_633_894)

        let manifestTrack = try XCTUnwrap(BundleManifest.load(from: bundleURL).alignments.first)
        XCTAssertEqual(manifestTrack.mappedReadCount, 25)
        XCTAssertEqual(manifestTrack.unmappedReadCount, 5_633_894)

        let metadataPath = try XCTUnwrap(manifestTrack.metadataDBPath)
        let metadataDB = try AlignmentMetadataDatabase(
            url: bundleURL.appendingPathComponent(metadataPath)
        )
        XCTAssertEqual(metadataDB.getFileInfo("total_reads"), "5633919")
        XCTAssertEqual(metadataDB.getFileInfo("mapped_reads"), "25")
        XCTAssertEqual(metadataDB.getFileInfo("unmapped_reads"), "5633894")
    }

    /// The attach publishes reads, not alignment records. flagstat and idxstats of the supplementary fixture: 13 records
    /// for 11 reads, 12 mapped records of which 2 are supplementary, so 10 reads mapped and 1 did not.
    func testAttachPublishesReadsNotSupplementaryRecords() async throws {
        let bundleURL = try makeMinimalBundle(named: "supplementary-counts")
        let (stagedBAM, stagedIndex) = try makeStagedArtifacts(in: tempDir)
        let request = PreparedAlignmentAttachmentRequest(
            bundleURL: bundleURL,
            stagedBAMURL: stagedBAM,
            stagedIndexURL: stagedIndex,
            outputTrackID: "aln_supplementary",
            outputTrackName: "supplementary",
            relativeDirectory: "alignments"
        )
        let collector = StubPreparedAlignmentMetadataCollector(
            idxstatsOutput: "fixture1\t1000\t12\t0\n*\t0\t0\t1\n",
            flagstatOutput: """
            13 + 0 in total (QC-passed reads + QC-failed reads)
            11 + 0 primary
            0 + 0 secondary
            2 + 0 supplementary
            0 + 0 duplicates
            0 + 0 primary duplicates
            12 + 0 mapped (92.31% : N/A)
            10 + 0 primary mapped (90.91% : N/A)
            """
        )

        let result = try await PreparedAlignmentAttachmentService(
            metadataCollector: collector
        ).attach(request: request)

        XCTAssertEqual(result.trackInfo.mappedReadCount, 10)
        XCTAssertEqual(result.trackInfo.unmappedReadCount, 1)
        let manifestTrack = try XCTUnwrap(BundleManifest.load(from: bundleURL).alignments.first)
        XCTAssertEqual(manifestTrack.mappedReadCount, 10)
        let metadataPath = try XCTUnwrap(manifestTrack.metadataDBPath)
        let metadataDB = try AlignmentMetadataDatabase(url: bundleURL.appendingPathComponent(metadataPath))
        XCTAssertEqual(metadataDB.getFileInfo("total_reads"), "11")
        XCTAssertEqual(metadataDB.getFileInfo("mapped_reads"), "10")
        XCTAssertEqual(metadataDB.getFileInfo("unmapped_reads"), "1")
    }

    /// 2.13 lane 13.16, review Fix 1. The attach moves the staged BAM and index into the bundle, and a caller such as
    /// `bam adopt-mapping` stages the user's only copy. When a later step throws, the attach gives both back to the
    /// staged paths, removes only what it made and restores the manifest's bytes.
    func testAFailedAttachReturnsTheStagedBAMAndIndex() async throws {
        let failures: [(String, PreparedAlignmentAttachmentService)] = [
            ("metadata", PreparedAlignmentAttachmentService(metadataCollector: FailingPreparedAlignmentMetadataCollector())),
            ("manifest", PreparedAlignmentAttachmentService(
                metadataCollector: StubPreparedAlignmentMetadataCollector(),
                manifestSaver: { _, _ in throw CocoaError(.fileWriteUnknown) }
            )),
        ]
        for (step, service) in failures {
            let bundleURL = try makeMinimalBundle(named: "failed-\(step)")
            let staging = tempDir.appendingPathComponent("staging-\(step)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let (stagedBAM, stagedIndex) = try makeStagedArtifacts(in: staging)
            let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
            let manifestBefore = try Data(contentsOf: manifestURL)

            do {
                _ = try await service.attach(request: failingRequest(bundleURL: bundleURL, bam: stagedBAM, index: stagedIndex))
                XCTFail("the \(step) step throws, so the attach throws")
            } catch {}

            XCTAssertEqual(try? Data(contentsOf: stagedBAM), Data("bam-bytes".utf8), "\(step): the staged BAM is back with its bytes")
            XCTAssertEqual(try? Data(contentsOf: stagedIndex), Data("bai-bytes".utf8), "\(step): the staged index is back with its bytes")
            let left = try FileManager.default.contentsOfDirectory(atPath: bundleURL.appendingPathComponent("alignments").path)
            XCTAssertEqual(left, [], "\(step): the bundle keeps no BAM, index or stats database of the run")
            XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore, "\(step): manifest.json holds its original bytes")
        }
    }

    /// Review Fix 1, ruling 1. When a file already sits at the staged path the BAM cannot go back, so the attach
    /// leaves it in the bundle and never deletes it.
    func testAFailedAttachNeverDeletesABAMItCannotGiveBack() async throws {
        let bundleURL = try makeMinimalBundle(named: "failed-occupied")
        let (stagedBAM, stagedIndex) = try makeStagedArtifacts(in: tempDir)
        let service = PreparedAlignmentAttachmentService(
            metadataCollector: FailingPreparedAlignmentMetadataCollector(occupying: stagedBAM)
        )

        do {
            _ = try await service.attach(request: failingRequest(bundleURL: bundleURL, bam: stagedBAM, index: stagedIndex))
            XCTFail("the metadata step throws, so the attach throws")
        } catch {}

        let bundleBAM = bundleURL.appendingPathComponent("alignments/aln_failed.bam")
        XCTAssertEqual(try? Data(contentsOf: bundleBAM), Data("bam-bytes".utf8), "the BAM stays in the bundle when its staged path is taken")
        XCTAssertEqual(try? Data(contentsOf: stagedBAM), Data("newer".utf8), "the file at the staged path is left alone")
        XCTAssertEqual(try? Data(contentsOf: stagedIndex), Data("bai-bytes".utf8), "the index still goes back")
    }

    // MARK: - Fixtures

    private func failingRequest(bundleURL: URL, bam: URL, index: URL) -> PreparedAlignmentAttachmentRequest {
        PreparedAlignmentAttachmentRequest(
            bundleURL: bundleURL,
            stagedBAMURL: bam,
            stagedIndexURL: index,
            outputTrackID: "aln_failed",
            outputTrackName: "failed",
            relativeDirectory: "alignments"
        )
    }

    private func makeMinimalBundle(named name: String) throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("genome", isDirectory: true),
            withIntermediateDirectories: true
        )
        try ">chr1\nACGT\n".write(
            to: bundleURL.appendingPathComponent("genome/sequence.fa"),
            atomically: true,
            encoding: .utf8
        )
        try "chr1\t4\t6\t4\t5\n".write(
            to: bundleURL.appendingPathComponent("genome/sequence.fa.fai"),
            atomically: true,
            encoding: .utf8
        )
        let manifest = BundleManifest(
            name: name,
            identifier: "org.lungfish.test.\(name.lowercased())",
            source: SourceInfo(organism: "Test organism", assembly: "Test assembly"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 4,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 4, offset: 6, lineBases: 4, lineWidth: 5)
                ]
            )
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    private func makeStagedArtifacts(in directory: URL) throws -> (bam: URL, index: URL) {
        let bam = directory.appendingPathComponent("staged-\(UUID().uuidString).bam")
        let index = URL(fileURLWithPath: bam.path + ".bai")
        try Data("bam-bytes".utf8).write(to: bam)
        try Data("bai-bytes".utf8).write(to: index)
        return (bam, index)
    }
}

/// A metadata collector whose step throws, as samtools does on a file it cannot read. When `occupying` names a path,
/// it first writes a file there, so the attach finds the staged path taken.
private struct FailingPreparedAlignmentMetadataCollector: PreparedAlignmentMetadataCollecting {
    var occupying: URL?

    func collectMetadata(
        bamURL: URL,
        indexURL: URL,
        format: AlignmentFormat,
        referenceFastaPath: String?
    ) async throws -> PreparedAlignmentMetadataSnapshot {
        if let occupying {
            try Data("newer".utf8).write(to: occupying)
        }
        throw CocoaError(.fileReadCorruptFile)
    }
}

/// Stub metadata collector avoiding a real samtools dependency for this attach-commit
/// unit test -- only the manifest read/collision-check/commit ordering is under test.
private struct StubPreparedAlignmentMetadataCollector: PreparedAlignmentMetadataCollecting {
    var idxstatsOutput = "chr1\t4\t0\t0\n"
    var flagstatOutput = "0 + 0 in total (QC-passed reads + QC-failed reads)\n"

    func collectMetadata(
        bamURL: URL,
        indexURL: URL,
        format: AlignmentFormat,
        referenceFastaPath: String?
    ) async throws -> PreparedAlignmentMetadataSnapshot {
        PreparedAlignmentMetadataSnapshot(
            idxstatsOutput: idxstatsOutput,
            flagstatOutput: flagstatOutput,
            headerText: "@HD\tVN:1.6\tSO:coordinate\n"
        )
    }
}
