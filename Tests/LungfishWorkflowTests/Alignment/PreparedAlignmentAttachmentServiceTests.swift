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

    // MARK: - Fixtures

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
