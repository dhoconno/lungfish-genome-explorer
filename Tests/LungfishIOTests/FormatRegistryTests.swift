// FormatRegistryTests.swift - Safety-net tests for FormatRegistry
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// Tests for the central format registry, verifying format detection,
/// importer/exporter lookup, and extension/MIME type mapping completeness.
///
/// FormatRegistry is an actor singleton, so all tests use `await`.
final class FormatRegistryTests: XCTestCase {

    // MARK: - Built-in Format Count

    /// The registry must ship with a meaningful number of built-in descriptors.
    /// If this drops to zero, format detection is completely broken.
    func testBuiltInFormatsCountIsGreaterThanZero() async {
        let registry = FormatRegistry.shared
        let formats = await registry.registeredFormats
        XCTAssertGreaterThan(formats.count, 0, "Registry should contain built-in format descriptors")
    }

    /// Verify the exact set of expected genomic formats are registered.
    /// This guards against accidental removal of a format during refactoring.
    func testExpectedGenomicFormatsAreRegistered() async {
        let registry = FormatRegistry.shared
        let formats = await registry.registeredFormats

        let expectedFormats: [FormatIdentifier] = [
            .fasta, .fastq, .genbank,
            .gff3, .gtf, .bed,
            .vcf, .bcf,
            .sam, .bam, .cram,
            .bigwig, .bigbed, .bedgraph,
            .fai, .bai,
        ]

        for expected in expectedFormats {
            XCTAssertTrue(
                formats.contains(expected),
                "Expected format '\(expected.id)' to be registered"
            )
        }
    }

    // MARK: - Format Detection from File Extension

    /// Detect FASTA from the .fasta extension.
    func testDetectFormatFromFastaExtension() async {
        let registry = FormatRegistry.shared
        let url = URL(fileURLWithPath: "/tmp/test.fasta")
        let format = await registry.detectFormat(url: url)
        XCTAssertEqual(format, .fasta)
    }

    /// Detect FASTA from the short .fa extension.
    func testDetectFormatFromFaShortExtension() async {
        let registry = FormatRegistry.shared
        let url = URL(fileURLWithPath: "/tmp/genome.fa")
        let format = await registry.detectFormat(url: url)
        XCTAssertEqual(format, .fasta)
    }

    /// Detect VCF from the .vcf extension.
    func testDetectFormatFromVcfExtension() async {
        let registry = FormatRegistry.shared
        let url = URL(fileURLWithPath: "/tmp/variants.vcf")
        let format = await registry.detectFormat(url: url)
        XCTAssertEqual(format, .vcf)
    }

    /// Detect GFF3 from the .gff3 extension.
    func testDetectFormatFromGff3Extension() async {
        let registry = FormatRegistry.shared
        let url = URL(fileURLWithPath: "/tmp/annotations.gff3")
        let format = await registry.detectFormat(url: url)
        XCTAssertEqual(format, .gff3)
    }

    /// Detect BED from the .bed extension.
    func testDetectFormatFromBedExtension() async {
        let registry = FormatRegistry.shared
        let url = URL(fileURLWithPath: "/tmp/features.bed")
        let format = await registry.detectFormat(url: url)
        XCTAssertEqual(format, .bed)
    }

    /// Detect BAM from the .bam extension.
    func testDetectFormatFromBamExtension() async {
        let registry = FormatRegistry.shared
        let url = URL(fileURLWithPath: "/tmp/aligned.bam")
        let format = await registry.detectFormat(url: url)
        XCTAssertEqual(format, .bam)
    }

    /// Detect GenBank from the .gbk extension.
    func testDetectFormatFromGenbankExtension() async {
        let registry = FormatRegistry.shared
        let url = URL(fileURLWithPath: "/tmp/sequence.gbk")
        let format = await registry.detectFormat(url: url)
        XCTAssertEqual(format, .genbank)
    }

    // MARK: - Gzipped Compound Extension Detection

    /// Detect FASTA from a gzipped compound extension (.fasta.gz).
    /// The registry strips .gz and detects the base extension.
    func testDetectFormatFromGzippedFastaExtension() async {
        let registry = FormatRegistry.shared
        let url = URL(fileURLWithPath: "/tmp/genome.fasta.gz")
        let format = await registry.detectFormat(url: url)
        XCTAssertEqual(format, .fasta, "Should detect FASTA from .fasta.gz compound extension")
    }

    /// Detect FASTA from .fa.gz compound extension.
    func testDetectFormatFromGzippedFaExtension() async {
        let registry = FormatRegistry.shared
        let url = URL(fileURLWithPath: "/tmp/genome.fa.gz")
        let format = await registry.detectFormat(url: url)
        XCTAssertEqual(format, .fasta, "Should detect FASTA from .fa.gz compound extension")
    }

    /// Detect VCF from a gzipped compound extension (.vcf.gz).
    func testDetectFormatFromGzippedVcfExtension() async {
        let registry = FormatRegistry.shared
        let url = URL(fileURLWithPath: "/tmp/variants.vcf.gz")
        let format = await registry.detectFormat(url: url)
        XCTAssertEqual(format, .vcf, "Should detect VCF from .vcf.gz compound extension")
    }

    // MARK: - Unknown Format Handling

    /// An unrecognized extension for a nonexistent file should return nil.
    func testUnknownExtensionReturnsNil() async {
        let registry = FormatRegistry.shared
        let url = URL(fileURLWithPath: "/tmp/data.xyz123")
        let format = await registry.detectFormat(url: url)
        XCTAssertNil(format, "Unknown extension should return nil format")
    }

    // MARK: - Importer Lookup

    /// FASTA has a built-in importer; lookup by identifier should succeed.
    func testImporterLookupForFasta() async {
        let registry = FormatRegistry.shared
        let importer = await registry.importer(for: .fasta)
        XCTAssertNotNil(importer, "FASTA importer should be registered")
        XCTAssertEqual(importer?.descriptor.identifier, .fasta)
    }

    /// GenBank has a built-in importer.
    func testImporterLookupForGenBank() async {
        let registry = FormatRegistry.shared
        let importer = await registry.importer(for: .genbank)
        XCTAssertNotNil(importer, "GenBank importer should be registered")
    }

    /// GFF3 has a built-in importer.
    func testImporterLookupForGff3() async {
        let registry = FormatRegistry.shared
        let importer = await registry.importer(for: .gff3)
        XCTAssertNotNil(importer, "GFF3 importer should be registered")
    }

    /// Readable formats should contain at least the three built-in importers.
    func testReadableFormatsContainsBuiltInImporters() async {
        let registry = FormatRegistry.shared
        let readable = await registry.readableFormats
        XCTAssertTrue(readable.contains(.fasta), "Readable formats should include FASTA")
        XCTAssertTrue(readable.contains(.genbank), "Readable formats should include GenBank")
        XCTAssertTrue(readable.contains(.gff3), "Readable formats should include GFF3")
    }

    // MARK: - Exporter Lookup

    /// FASTA has a built-in exporter; lookup by identifier should succeed.
    func testExporterLookupForFasta() async {
        let registry = FormatRegistry.shared
        let exporter = await registry.exporter(for: .fasta)
        XCTAssertNotNil(exporter, "FASTA exporter should be registered")
        XCTAssertEqual(exporter?.descriptor.identifier, .fasta)
    }

    /// GenBank has a built-in exporter.
    func testExporterLookupForGenBank() async {
        let registry = FormatRegistry.shared
        let exporter = await registry.exporter(for: .genbank)
        XCTAssertNotNil(exporter, "GenBank exporter should be registered")
    }

    /// GFF3 has a built-in exporter.
    func testExporterLookupForGff3() async {
        let registry = FormatRegistry.shared
        let exporter = await registry.exporter(for: .gff3)
        XCTAssertNotNil(exporter, "GFF3 exporter should be registered")
    }

    /// Writable formats should contain at least the three built-in exporters.
    func testWritableFormatsContainsBuiltInExporters() async {
        let registry = FormatRegistry.shared
        let writable = await registry.writableFormats
        XCTAssertTrue(writable.contains(.fasta), "Writable formats should include FASTA")
        XCTAssertTrue(writable.contains(.genbank), "Writable formats should include GenBank")
        XCTAssertTrue(writable.contains(.gff3), "Writable formats should include GFF3")
    }

    // MARK: - Extension-to-Format Mapping Completeness

    /// Every built-in descriptor must have at least one file extension.
    func testAllDescriptorsHaveAtLeastOneExtension() async {
        let registry = FormatRegistry.shared
        let descriptors = await registry.allDescriptors

        for descriptor in descriptors {
            XCTAssertFalse(
                descriptor.extensions.isEmpty,
                "Descriptor '\(descriptor.displayName)' should have at least one file extension"
            )
        }
    }

    /// Every genomic format descriptor must have a non-empty display name.
    func testAllDescriptorsHaveNonEmptyDisplayName() async {
        let registry = FormatRegistry.shared
        let descriptors = await registry.allDescriptors

        for descriptor in descriptors {
            XCTAssertFalse(
                descriptor.displayName.isEmpty,
                "Descriptor '\(descriptor.identifier.id)' should have a non-empty display name"
            )
        }
    }

    // MARK: - MIME Type Mapping

    /// The FASTA MIME type should resolve to the FASTA format.
    func testMimeTypeMappingForFasta() async {
        let registry = FormatRegistry.shared
        let format = await registry.formatForMimeType("text/x-fasta")
        XCTAssertEqual(format, .fasta, "MIME type 'text/x-fasta' should map to FASTA format")
    }

    /// The VCF MIME type should resolve to the VCF format.
    func testMimeTypeMappingForVcf() async {
        let registry = FormatRegistry.shared
        let format = await registry.formatForMimeType("text/x-vcf")
        XCTAssertEqual(format, .vcf, "MIME type 'text/x-vcf' should map to VCF format")
    }

    /// The BAM MIME type should resolve to the BAM format.
    func testMimeTypeMappingForBam() async {
        let registry = FormatRegistry.shared
        let format = await registry.formatForMimeType("application/x-bam")
        XCTAssertEqual(format, .bam, "MIME type 'application/x-bam' should map to BAM format")
    }

    /// MIME type lookup is case-insensitive.
    func testMimeTypeLookupIsCaseInsensitive() async {
        let registry = FormatRegistry.shared
        let format = await registry.formatForMimeType("TEXT/X-FASTA")
        XCTAssertEqual(format, .fasta, "MIME type lookup should be case-insensitive")
    }

    /// An unknown MIME type should return nil.
    func testUnknownMimeTypeReturnsNil() async {
        let registry = FormatRegistry.shared
        let format = await registry.formatForMimeType("application/x-unknown-format")
        XCTAssertNil(format, "Unknown MIME type should return nil")
    }

    // MARK: - Capability Queries

    /// Querying for nucleotide sequence capability should return FASTA and others.
    func testFormatsWithNucleotideSequenceCapability() async {
        let registry = FormatRegistry.shared
        let formats = await registry.formats(supporting: .nucleotideSequence)
        XCTAssertTrue(formats.contains(.fasta), "FASTA should support nucleotide sequences")
        XCTAssertTrue(formats.contains(.fastq), "FASTQ should support nucleotide sequences")
        XCTAssertTrue(formats.contains(.genbank), "GenBank should support nucleotide sequences")
    }

    /// Querying for annotations capability should return GFF3, BED, etc.
    func testFormatsWithAnnotationCapability() async {
        let registry = FormatRegistry.shared
        let formats = await registry.formats(supporting: .annotations)
        XCTAssertTrue(formats.contains(.gff3), "GFF3 should support annotations")
        XCTAssertTrue(formats.contains(.bed), "BED should support annotations")
        XCTAssertTrue(formats.contains(.genbank), "GenBank should support annotations")
    }

    /// Querying for variant capability should return VCF and BCF.
    func testFormatsWithVariantCapability() async {
        let registry = FormatRegistry.shared
        let formats = await registry.formats(supporting: .variants)
        XCTAssertTrue(formats.contains(.vcf), "VCF should support variants")
        XCTAssertTrue(formats.contains(.bcf), "BCF should support variants")
    }

    // MARK: - Descriptor Lookup by Identifier

    /// Looking up a descriptor by its identifier should return the correct descriptor.
    func testDescriptorLookupByIdentifier() async {
        let registry = FormatRegistry.shared
        let descriptor = await registry.descriptor(for: .bam)
        XCTAssertNotNil(descriptor)
        XCTAssertEqual(descriptor?.displayName, "BAM")
        XCTAssertTrue(descriptor?.isBinary ?? false, "BAM should be marked as binary")
        XCTAssertTrue(descriptor?.requiresIndex ?? false, "BAM should require an index")
        XCTAssertEqual(descriptor?.indexFormat, .bai, "BAM index format should be .bai")
    }

    /// A descriptor for a nonexistent identifier should return nil.
    func testDescriptorLookupForNonexistentIdentifier() async {
        let registry = FormatRegistry.shared
        let descriptor = await registry.descriptor(for: FormatIdentifier("nonexistent"))
        XCTAssertNil(descriptor, "Nonexistent format should return nil descriptor")
    }
}
