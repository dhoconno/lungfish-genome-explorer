// ReferenceBundleImportServiceTests.swift - Tests for reference import classification
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishWorkflow
@testable import LungfishApp

final class ReferenceBundleImportServiceTests: XCTestCase {
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
