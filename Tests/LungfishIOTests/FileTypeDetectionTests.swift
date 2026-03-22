// FileTypeDetectionTests.swift - Safety-net tests for format detection
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// Tests for FileTypeUtility extension-based format detection.
///
/// FileTypeUtility is the synchronous format detection engine used by
/// both ImportService and FormatRegistry. Testing it directly avoids
/// AppKit dependencies while covering the core detection logic.
final class FileTypeDetectionTests: XCTestCase {

    // MARK: - Sequence Formats

    func testDetectFASTAFromExtension() {
        let url = URL(fileURLWithPath: "/data/genome.fasta")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .sequence)
    }

    func testDetectFASTAFromFaExtension() {
        let url = URL(fileURLWithPath: "/data/genome.fa")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .sequence)
    }

    func testDetectFASTQFromExtension() {
        let url = URL(fileURLWithPath: "/data/reads.fastq")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .sequence)
    }

    func testDetectFASTQFromFqExtension() {
        let url = URL(fileURLWithPath: "/data/reads.fq")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .sequence)
    }

    func testDetectGenBankFromGbExtension() {
        let url = URL(fileURLWithPath: "/data/sequence.gb")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .sequence)
    }

    func testDetectGenBankFromGbkExtension() {
        let url = URL(fileURLWithPath: "/data/sequence.gbk")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .sequence)
    }

    func testDetectGenBankFromGbffExtension() {
        let url = URL(fileURLWithPath: "/data/sequence.gbff")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .sequence)
    }

    // MARK: - Annotation Formats

    func testDetectGFF3FromGffExtension() {
        let url = URL(fileURLWithPath: "/data/annotations.gff")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .annotation)
    }

    func testDetectGFF3FromGff3Extension() {
        let url = URL(fileURLWithPath: "/data/annotations.gff3")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .annotation)
    }

    func testDetectBEDFromExtension() {
        let url = URL(fileURLWithPath: "/data/regions.bed")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .annotation)
    }

    func testDetectGTFFromExtension() {
        let url = URL(fileURLWithPath: "/data/genes.gtf")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .annotation)
    }

    // MARK: - Variant Formats

    func testDetectVCFFromExtension() {
        let url = URL(fileURLWithPath: "/data/variants.vcf")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .variant)
    }

    func testDetectBCFFromExtension() {
        let url = URL(fileURLWithPath: "/data/variants.bcf")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .variant)
    }

    // MARK: - Alignment Formats

    func testDetectBAMFromExtension() {
        let url = URL(fileURLWithPath: "/data/aligned.bam")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .alignment)
    }

    func testDetectSAMFromExtension() {
        let url = URL(fileURLWithPath: "/data/aligned.sam")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .alignment)
    }

    func testDetectCRAMFromExtension() {
        let url = URL(fileURLWithPath: "/data/aligned.cram")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .alignment)
    }

    // MARK: - Gzip Compressed Format Detection

    func testDetectCompressedFASTAStripsGzExtension() {
        let url = URL(fileURLWithPath: "/data/genome.fa.gz")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .sequence, "Should detect inner .fa extension through .gz")
    }

    func testDetectCompressedVCFStripsGzExtension() {
        let url = URL(fileURLWithPath: "/data/variants.vcf.gz")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .variant, "Should detect inner .vcf extension through .gz")
    }

    func testDetectCompressedFASTQStripsGzExtension() {
        let url = URL(fileURLWithPath: "/data/reads.fastq.gz")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .sequence, "Should detect inner .fastq extension through .gz")
    }

    func testDetectCompressedGFF3StripsGzExtension() {
        let url = URL(fileURLWithPath: "/data/annotations.gff3.gz")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .annotation, "Should detect inner .gff3 extension through .gz")
    }

    func testBareGzFileDetectsAsCompressed() {
        let url = URL(fileURLWithPath: "/data/archive.gz")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .compressed)
    }

    func testCompressedFormatsDoNotSupportQuickLook() {
        let url = URL(fileURLWithPath: "/data/genome.fa.gz")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertFalse(info.supportsQuickLook, "Compressed files should not support QuickLook")
    }

    // MARK: - Case Insensitive Detection

    func testUppercaseExtensionDetected() {
        let url = URL(fileURLWithPath: "/data/genome.FASTA")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .sequence)
    }

    func testMixedCaseExtensionDetected() {
        let url = URL(fileURLWithPath: "/data/aligned.Bam")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .alignment)
    }

    func testUppercaseGzDetected() {
        let url = URL(fileURLWithPath: "/data/genome.fa.GZ")
        let info = FileTypeUtility.detect(url: url)
        // .GZ lowercased = "gz", inner ext .fa should resolve to sequence
        XCTAssertEqual(info.category, .sequence)
    }

    // MARK: - Unknown Format

    func testUnknownExtensionReturnsUnknownCategory() {
        let url = URL(fileURLWithPath: "/data/mystery.xyz")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .unknown)
    }

    func testUnknownExtensionSupportsQuickLookAsFallback() {
        let url = URL(fileURLWithPath: "/data/mystery.xyz")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertTrue(info.supportsQuickLook, "Unknown files should try QuickLook as fallback")
    }

    func testNoExtensionReturnsUnknown() {
        let url = URL(fileURLWithPath: "/data/noextension")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .unknown)
    }

    // MARK: - Genomics Format Flag

    func testSequenceFormatsAreGenomic() {
        let url = URL(fileURLWithPath: "/data/genome.fasta")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertTrue(info.isGenomicsFormat)
    }

    func testVariantFormatsAreGenomic() {
        let url = URL(fileURLWithPath: "/data/variants.vcf")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertTrue(info.isGenomicsFormat)
    }

    func testAlignmentFormatsAreGenomic() {
        let url = URL(fileURLWithPath: "/data/aligned.bam")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertTrue(info.isGenomicsFormat)
    }

    func testDocumentFormatsAreNotGenomic() {
        let url = URL(fileURLWithPath: "/data/report.pdf")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertFalse(info.isGenomicsFormat)
    }

    func testImageFormatsAreNotGenomic() {
        let url = URL(fileURLWithPath: "/data/plot.png")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertFalse(info.isGenomicsFormat)
    }

    // MARK: - Extension-Based Detection API

    func testDetectFromExtensionString() {
        let info = FileTypeUtility.detect(extension: "vcf")
        XCTAssertEqual(info.category, .variant)
    }

    func testIsKnownExtensionForGenomic() {
        XCTAssertTrue(FileTypeUtility.isKnownExtension("fasta"))
        XCTAssertTrue(FileTypeUtility.isKnownExtension("vcf"))
        XCTAssertTrue(FileTypeUtility.isKnownExtension("bam"))
    }

    func testIsKnownExtensionReturnsFalseForUnknown() {
        XCTAssertFalse(FileTypeUtility.isKnownExtension("xyz"))
        XCTAssertFalse(FileTypeUtility.isKnownExtension(""))
    }

    // MARK: - Coverage Formats

    func testDetectBigWigFromBwExtension() {
        let url = URL(fileURLWithPath: "/data/signal.bw")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .coverage)
    }

    func testDetectBedGraphFromExtension() {
        let url = URL(fileURLWithPath: "/data/signal.bedgraph")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .coverage)
    }

    // MARK: - Index Formats

    func testDetectFAIAsIndex() {
        let url = URL(fileURLWithPath: "/data/genome.fa.fai")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .index)
    }

    func testDetectBAIAsIndex() {
        let url = URL(fileURLWithPath: "/data/aligned.bam.bai")
        let info = FileTypeUtility.detect(url: url)
        XCTAssertEqual(info.category, .index)
    }
}
