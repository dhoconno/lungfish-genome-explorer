// AlignmentDuplicateServiceTests.swift - Tests for duplicate workflow helpers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class AlignmentDuplicateServiceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlignmentDuplicateServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testUniqueDeduplicatedBundleURLUsesDefaultSuffixWhenAvailable() {
        let source = tempDir.appendingPathComponent("example.lungfishref")
        let candidate = AlignmentDuplicateService.uniqueDeduplicatedBundleURL(for: source)
        XCTAssertEqual(candidate.lastPathComponent, "example-deduplicated.lungfishref")
    }

    func testUniqueDeduplicatedBundleURLAdvancesSuffixWhenExistingPathPresent() throws {
        let source = tempDir.appendingPathComponent("example.lungfishref")
        let existing = tempDir.appendingPathComponent("example-deduplicated.lungfishref")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)

        let candidate = AlignmentDuplicateService.uniqueDeduplicatedBundleURL(for: source)
        XCTAssertEqual(candidate.lastPathComponent, "example-deduplicated-2.lungfishref")
    }

    func testUniqueDeduplicatedBundleURLPrefersExplicitOutputWhenUnused() {
        let source = tempDir.appendingPathComponent("example.lungfishref")
        let preferred = tempDir.appendingPathComponent("custom-output.lungfishref")
        let candidate = AlignmentDuplicateService.uniqueDeduplicatedBundleURL(
            for: source,
            preferred: preferred
        )
        XCTAssertEqual(candidate, preferred)
    }

    func testAlignmentDuplicateErrorDescriptionsAreNonEmpty() {
        let errors: [AlignmentDuplicateError] = [
            .noAlignmentTracks,
            .sourcePathNotFound("/tmp/missing.bam"),
            .samtoolsFailed("mock failure")
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        }
    }

    func testMarkDuplicatesInBundleAttachesMarkedTracksUnderMarkedDirectory() async throws {
        let fixture = try DuplicateWorkflowFixture.make(rootURL: tempDir)
        let attachmentService = PreparedAlignmentAttachmentService(
            metadataCollector: DuplicateWorkflowMetadataCollector()
        )
        let markdupPipeline = RecordingDuplicateMarkdupPipeline()

        let result = try await AlignmentDuplicateService.markDuplicatesInBundle(
            bundleURL: fixture.bundleURL,
            markdupPipeline: markdupPipeline,
            attachmentService: attachmentService,
            trackIDProvider: { "marked-track" }
        )

        XCTAssertEqual(result.processedTracks, 1)
        XCTAssertEqual(result.newTrackIds, ["marked-track"])

        let manifest = try BundleManifest.load(from: fixture.bundleURL)
        XCTAssertEqual(manifest.alignments.map(\.id), ["marked-track"])
        XCTAssertEqual(manifest.alignments.first?.sourcePath, "alignments/marked/marked-track.bam")
        XCTAssertEqual(manifest.alignments.first?.indexPath, "alignments/marked/marked-track.bam.bai")
        XCTAssertEqual(manifest.alignments.first?.metadataDBPath, "alignments/marked/marked-track.stats.db")
        XCTAssertEqual(manifest.alignments.first?.name, "Fixture BAM [dup-marked]")

        let invocations = await markdupPipeline.invocations
        XCTAssertEqual(invocations.map(\.removeDuplicates), [false])
        XCTAssertEqual(invocations.map(\.outputURL.lastPathComponent), ["aln-1.marked.bam"])

        let metadataRelativePath = try XCTUnwrap(manifest.alignments.first?.metadataDBPath)
        let metadataURL = fixture.bundleURL.appendingPathComponent(metadataRelativePath)
        let metadataDB = try AlignmentMetadataDatabase.openForUpdate(at: metadataURL)
        XCTAssertEqual(metadataDB.getFileInfo("original_source_path"), fixture.sourceBAMURL.path)
        XCTAssertEqual(metadataDB.getFileInfo("original_source_format"), AlignmentFormat.bam.rawValue)
        XCTAssertEqual(metadataDB.getFileInfo("derivation_kind"), "duplicate_marked_alignment")
        XCTAssertEqual(metadataDB.getFileInfo("derivation_source_track_id"), "aln-1")
        XCTAssertEqual(metadataDB.getFileInfo("derivation_source_manifest_path"), "alignments/source.bam")
        XCTAssertEqual(
            metadataDB.provenanceHistory().map { $0.subcommand },
            ["markdup"]
        )
    }

    func testCreateDeduplicatedBundleAttachesTracksUnderDeduplicatedDirectory() async throws {
        let fixture = try DuplicateWorkflowFixture.make(rootURL: tempDir)
        let outputBundleURL = tempDir.appendingPathComponent("fixture-deduplicated.lungfishref", isDirectory: true)
        let attachmentService = PreparedAlignmentAttachmentService(
            metadataCollector: DuplicateWorkflowMetadataCollector()
        )
        let markdupPipeline = RecordingDuplicateMarkdupPipeline()

        let result = try await AlignmentDuplicateService.createDeduplicatedBundle(
            from: fixture.bundleURL,
            outputBundleURL: outputBundleURL,
            markdupPipeline: markdupPipeline,
            attachmentService: attachmentService,
            trackIDProvider: { "deduplicated-track" }
        )

        XCTAssertEqual(result.bundleURL.standardizedFileURL, outputBundleURL.standardizedFileURL)
        XCTAssertEqual(result.processedTracks, 1)
        XCTAssertEqual(result.newTrackIds, ["deduplicated-track"])

        let sourceManifest = try BundleManifest.load(from: fixture.bundleURL)
        XCTAssertEqual(sourceManifest.alignments.map(\.id), ["aln-1"])

        let copiedManifest = try BundleManifest.load(from: outputBundleURL)
        XCTAssertEqual(copiedManifest.alignments.map(\.id), ["deduplicated-track"])
        XCTAssertEqual(
            copiedManifest.alignments.first?.sourcePath,
            "alignments/deduplicated/deduplicated-track.bam"
        )
        XCTAssertEqual(
            copiedManifest.alignments.first?.indexPath,
            "alignments/deduplicated/deduplicated-track.bam.bai"
        )
        XCTAssertEqual(
            copiedManifest.alignments.first?.metadataDBPath,
            "alignments/deduplicated/deduplicated-track.stats.db"
        )
        XCTAssertEqual(copiedManifest.alignments.first?.name, "Fixture BAM [deduplicated]")

        let invocations = await markdupPipeline.invocations
        XCTAssertEqual(invocations.map(\.removeDuplicates), [true])
        XCTAssertEqual(invocations.map(\.outputURL.lastPathComponent), ["aln-1.deduplicated.bam"])

        let metadataRelativePath = try XCTUnwrap(copiedManifest.alignments.first?.metadataDBPath)
        let metadataURL = outputBundleURL.appendingPathComponent(metadataRelativePath)
        let metadataDB = try AlignmentMetadataDatabase.openForUpdate(at: metadataURL)
        XCTAssertEqual(
            metadataDB.getFileInfo("original_source_path"),
            outputBundleURL.appendingPathComponent("alignments/source.bam").path
        )
        XCTAssertEqual(metadataDB.getFileInfo("original_source_format"), AlignmentFormat.bam.rawValue)
        XCTAssertEqual(metadataDB.getFileInfo("derivation_kind"), "deduplicated_alignment")
        XCTAssertEqual(metadataDB.getFileInfo("derivation_source_track_id"), "aln-1")
        XCTAssertEqual(
            metadataDB.provenanceHistory().map { $0.subcommand },
            ["markdup"]
        )
    }

    func testMarkDuplicatesRollsBackAttachedTrackWhenMetadataAppendFails() async throws {
        let fixture = try DuplicateWorkflowFixture.make(rootURL: tempDir)
        let attachmentService = PreparedAlignmentAttachmentService(
            metadataCollector: DuplicateWorkflowMetadataCollector()
        )
        let markdupPipeline = RecordingDuplicateMarkdupPipeline()

        do {
            _ = try await AlignmentDuplicateService.markDuplicatesInBundle(
                bundleURL: fixture.bundleURL,
                markdupPipeline: markdupPipeline,
                attachmentService: attachmentService,
                metadataAppender: { _, _, _, _, _ in
                    throw DuplicateMetadataAppendFailure.injected
                },
                trackIDProvider: { "marked-track" }
            )
            XCTFail("Expected metadata append failure")
        } catch {
            XCTAssertEqual(error as? DuplicateMetadataAppendFailure, .injected)
        }

        let manifest = try BundleManifest.load(from: fixture.bundleURL)
        XCTAssertEqual(manifest.alignments.map(\.id), ["aln-1"])
        XCTAssertEqual(manifest.alignments.first?.sourcePath, "alignments/source.bam")
        XCTAssertEqual(manifest.alignments.first?.metadataDBPath, "alignments/source.stats.db")

        let rolledBackBAMURL = fixture.bundleURL.appendingPathComponent("alignments/marked/marked-track.bam")
        let rolledBackIndexURL = fixture.bundleURL.appendingPathComponent("alignments/marked/marked-track.bam.bai")
        let rolledBackMetadataURL = fixture.bundleURL.appendingPathComponent("alignments/marked/marked-track.stats.db")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rolledBackBAMURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rolledBackIndexURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rolledBackMetadataURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceBAMURL.path))
    }
}

private struct DuplicateWorkflowFixture {
    let bundleURL: URL
    let sourceBAMURL: URL

    static func make(rootURL: URL) throws -> DuplicateWorkflowFixture {
        let bundleURL = rootURL.appendingPathComponent("fixture.lungfishref", isDirectory: true)
        let alignmentsURL = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: alignmentsURL, withIntermediateDirectories: true)

        let sourceBAMURL = alignmentsURL.appendingPathComponent("source.bam")
        let sourceIndexURL = alignmentsURL.appendingPathComponent("source.bam.bai")
        let sourceMetadataURL = alignmentsURL.appendingPathComponent("source.stats.db")
        FileManager.default.createFile(atPath: sourceBAMURL.path, contents: Data("bam".utf8))
        FileManager.default.createFile(atPath: sourceIndexURL.path, contents: Data("bai".utf8))
        FileManager.default.createFile(atPath: sourceMetadataURL.path, contents: Data())

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Duplicates",
            identifier: "duplicates.bundle",
            source: SourceInfo(organism: "Virus", assembly: "Fixture", database: "FixtureDB"),
            genome: nil,
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-1",
                    name: "Fixture BAM",
                    format: .bam,
                    sourcePath: "alignments/source.bam",
                    indexPath: "alignments/source.bam.bai",
                    metadataDBPath: "alignments/source.stats.db"
                )
            ]
        )
        try manifest.save(to: bundleURL)
        return DuplicateWorkflowFixture(bundleURL: bundleURL, sourceBAMURL: sourceBAMURL)
    }
}

private actor RecordingDuplicateMarkdupPipeline: AlignmentMarkdupPipelining {
    struct Invocation: Equatable {
        let inputURL: URL
        let outputURL: URL
        let removeDuplicates: Bool
    }

    private(set) var invocations: [Invocation] = []

    func run(
        inputURL: URL,
        outputURL: URL,
        removeDuplicates: Bool,
        referenceFastaPath: String?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> AlignmentMarkdupPipelineResult {
        invocations.append(
            Invocation(
                inputURL: inputURL,
                outputURL: outputURL,
                removeDuplicates: removeDuplicates
            )
        )

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: outputURL.path, contents: Data("bam".utf8))
        FileManager.default.createFile(atPath: outputURL.path + ".bai", contents: Data("bai".utf8))

        let tempDir = outputURL.deletingLastPathComponent()
        return AlignmentMarkdupPipelineResult(
            outputURL: outputURL,
            indexURL: URL(fileURLWithPath: outputURL.path + ".bai"),
            intermediateFiles: AlignmentMarkdupIntermediateFiles(
                nameSortedBAM: tempDir.appendingPathComponent("name.sorted.bam"),
                fixmateBAM: tempDir.appendingPathComponent("fixmate.bam"),
                coordinateSortedBAM: tempDir.appendingPathComponent("coord.sorted.bam")
            ),
            commandHistory: [
                AlignmentCommandExecutionRecord(
                    arguments: ["markdup", outputURL.path],
                    inputFile: inputURL.path,
                    outputFile: outputURL.path
                )
            ]
        )
    }
}

private struct DuplicateWorkflowMetadataCollector: PreparedAlignmentMetadataCollecting {
    func collectMetadata(
        bamURL: URL,
        indexURL: URL,
        format: AlignmentFormat,
        referenceFastaPath: String?
    ) async throws -> PreparedAlignmentMetadataSnapshot {
        PreparedAlignmentMetadataSnapshot(
            idxstatsOutput: "chr1\t1000\t7\t2\n*\t0\t0\t0\n",
            flagstatOutput: """
            9 + 0 in total (QC-passed reads + QC-failed reads)
            7 + 0 mapped (77.78% : N/A)
            """,
            headerText: """
            @HD\tVN:1.6\tSO:coordinate
            @SQ\tSN:chr1\tLN:1000
            @RG\tID:rg1\tSM:sampleA
            """
        )
    }
}

private enum DuplicateMetadataAppendFailure: Error, Equatable {
    case injected
}
