// TestFixtures.swift — Shared test fixture accessors
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Test data from nf-core/test-datasets (MIT License).
// SARS-CoV-2 reference MT192765.1, ~30 kb genome.

import Foundation

/// Provides type-safe access to shared test fixture files.
///
/// Fixtures live in `Tests/Fixtures/` and are copied into the test bundle
/// via `.copy("Fixtures")` in Package.swift resource declarations.
///
/// Usage:
/// ```swift
/// let ref = TestFixtures.sarscov2.reference
/// let (r1, r2) = TestFixtures.sarscov2.pairedFastq
/// ```
public enum TestFixtures {

    /// SARS-CoV-2 test dataset (~85 KB total).
    ///
    /// All files are internally consistent: the reads align to the reference,
    /// variants were called from those reads, and annotations match the genome.
    public enum sarscov2 {
        private static let dir = "sarscov2"

        // MARK: - Reference

        /// SARS-CoV-2 reference genome (MT192765.1, ~30 kb).
        public static var reference: URL { fixture("genome.fasta") }

        /// samtools faidx index for the reference.
        public static var referenceIndex: URL { fixture("genome.fasta.fai") }

        // MARK: - Annotations

        /// Gene annotations in GFF3 format (orf1ab, S, M, N, etc.).
        public static var gff3: URL { fixture("genome.gff3") }

        /// Gene annotations in GTF format.
        public static var gtf: URL { fixture("genome.gtf") }

        /// ARTIC primer BED file.
        public static var bed: URL { fixture("test.bed") }

        // MARK: - Reads

        /// Paired-end Illumina FASTQ files (gzipped, ~200 reads each).
        public static var pairedFastq: (r1: URL, r2: URL) {
            (fixture("test_1.fastq.gz"), fixture("test_2.fastq.gz"))
        }

        /// Forward read FASTQ only.
        public static var fastqR1: URL { fixture("test_1.fastq.gz") }

        /// Reverse read FASTQ only.
        public static var fastqR2: URL { fixture("test_2.fastq.gz") }

        // MARK: - Alignments

        /// Sorted BAM file (paired-end reads aligned to genome.fasta).
        public static var sortedBam: URL { fixture("test.paired_end.sorted.bam") }

        /// BAM index (.bai).
        public static var bamIndex: URL { fixture("test.paired_end.sorted.bam.bai") }

        // MARK: - Variants

        /// VCF with variant calls from the BAM.
        public static var vcf: URL { fixture("test.vcf") }

        /// bgzipped VCF.
        public static var vcfGz: URL { fixture("test.vcf.gz") }

        /// tabix index for the bgzipped VCF.
        public static var vcfTbi: URL { fixture("test.vcf.gz.tbi") }

        // MARK: - Helpers

        private static func fixture(_ name: String) -> URL {
            let url = fixturesBaseURL.appendingPathComponent(dir).appendingPathComponent(name)
            precondition(
                FileManager.default.fileExists(atPath: url.path),
                "Test fixture missing: \(dir)/\(name). Run from a test target with .copy(\"Fixtures\") in Package.swift."
            )
            return url
        }
    }

    /// NAO-MGS toy dataset (35 rows, 4 taxa, v2 format).
    ///
    /// Derived from a real CASPER wastewater surveillance dataset.
    /// Designed to test top-5 accession filtering, cross-taxon deduplication,
    /// and pair status variety (CP/UP/DP).
    public enum naomgs {
        private static let dir = "naomgs"

        /// Gzipped virus_hits_final.tsv (35 data rows, v2 column format).
        public static var virusHitsTsvGz: URL { fixture("virus_hits_final.tsv.gz") }

        private static func fixture(_ name: String) -> URL {
            let url = fixturesBaseURL.appendingPathComponent(dir).appendingPathComponent(name)
            precondition(
                FileManager.default.fileExists(atPath: url.path),
                "Test fixture missing: \(dir)/\(name). Run from a test target with .copy(\"Fixtures\") in Package.swift."
            )
            return url
        }
    }

    // MARK: - Base URL Resolution

    /// Resolves the Fixtures directory from the test bundle or source tree.
    ///
    /// SPM test bundles copy resources into `Bundle.module`, but the exact
    /// path varies. We try the bundle first, then fall back to walking up
    /// from `#file` to find `Tests/Fixtures/`.
    private static var fixturesBaseURL: URL {
        // Strategy 1: Bundle.module (works when test target declares .copy("Fixtures"))
        // SPM copies the Fixtures directory into the bundle's resource path.
        if let bundlePath = Bundle.module.resourceURL?
            .appendingPathComponent("Fixtures"),
           FileManager.default.fileExists(atPath: bundlePath.appendingPathComponent("sarscov2").path)
        {
            return bundlePath
        }

        // Strategy 2: Walk up from this source file to find Tests/Fixtures/
        // Useful when running from Xcode or when Bundle.module isn't set up.
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let check = candidate.appendingPathComponent("Fixtures/sarscov2")
            if FileManager.default.fileExists(atPath: check.path) {
                return candidate.appendingPathComponent("Fixtures")
            }
            candidate = candidate.deletingLastPathComponent()
        }

        fatalError("Cannot locate Tests/Fixtures directory. Ensure test fixtures are present.")
    }
}
