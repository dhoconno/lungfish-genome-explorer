// ReferenceBundleImportServiceTests.swift - Tests for reference import classification
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishWorkflow
@testable import LungfishApp

final class ReferenceBundleImportServiceTests: XCTestCase {
    @MainActor
    func testImportAsReferenceBundleRecordsOriginalSourceInProvenance() async throws {
        if let missingInfo = await NativeBundleBuilder().checkRequiredTools() {
            throw XCTSkip("Native reference bundle tools are unavailable: \(missingInfo.description)")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceBundleImportServiceTests-\(UUID().uuidString)", isDirectory: true)
        let outputDirectory = root.appendingPathComponent("References", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let sourceURL = root.appendingPathComponent("source.fa")
        try ">chr1\nACGTACGT\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        let result = try await ReferenceBundleImportService.shared.importAsReferenceBundle(
            sourceURL: sourceURL,
            outputDirectory: outputDirectory,
            preferredBundleName: "Imported Ref"
        )

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: result.bundleURL))
        let expectedCommand = [
            "lungfish-app",
            "reference-bundle-import",
            sourceURL.standardizedFileURL.path,
            "--output-directory",
            outputDirectory.standardizedFileURL.path,
            "--name",
            "Imported Ref",
        ]
        XCTAssertEqual(provenance.workflowName, "lungfish reference import")
        XCTAssertEqual(provenance.argv, expectedCommand)
        XCTAssertEqual(provenance.steps.first?.argv, expectedCommand)
        XCTAssertTrue(provenance.files.contains {
            $0.path == sourceURL.standardizedFileURL.path && $0.role == .input && $0.checksumSHA256 != nil
        })
        XCTAssertFalse(provenance.steps.flatMap(\.inputs).contains {
            $0.path.contains("ref-import-")
        })
        XCTAssertTrue(provenance.outputs.contains {
            $0.path.hasPrefix(result.bundleURL.path) && $0.checksumSHA256 != nil
        })
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: result.bundleURL
                .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
                .appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
                .path
        ))
    }

    func testClassifiesStandaloneReferenceExtensions() {
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/reference.fasta")),
            .standaloneReferenceSequence
        )
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/reference.gbff")),
            .standaloneReferenceSequence
        )
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/reference.embl")),
            .standaloneReferenceSequence
        )
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/reference.fa.gz")),
            .standaloneReferenceSequence
        )
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/reference.fa.bz2")),
            .standaloneReferenceSequence
        )
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/reference.fa.xz")),
            .standaloneReferenceSequence
        )
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/reference.fa.zst")),
            .standaloneReferenceSequence
        )
    }

    func testClassifiesTrackTypes() {
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/track.gff3")),
            .annotationTrack
        )
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/variants.vcf.gz")),
            .variantTrack
        )
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/aln.bam")),
            .alignmentTrack
        )
    }

    func testClassifiesUnsupportedType() {
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/notes.txt")),
            .unsupported
        )
    }

    func testNormalizedExtensionStripsCompressionWrapper() {
        XCTAssertEqual(
            ReferenceBundleImportService.normalizedExtension(for: URL(fileURLWithPath: "/tmp/a.fa.gz")),
            "fa"
        )
        XCTAssertEqual(
            ReferenceBundleImportService.normalizedExtension(for: URL(fileURLWithPath: "/tmp/a.gb.bgz")),
            "gb"
        )
        XCTAssertEqual(
            ReferenceBundleImportService.normalizedExtension(for: URL(fileURLWithPath: "/tmp/a.fna.bz2")),
            "fna"
        )
        XCTAssertEqual(
            ReferenceBundleImportService.normalizedExtension(for: URL(fileURLWithPath: "/tmp/a.fasta.xz")),
            "fasta"
        )
        XCTAssertEqual(
            ReferenceBundleImportService.normalizedExtension(for: URL(fileURLWithPath: "/tmp/a.fna.zstd")),
            "fna"
        )
    }
}
